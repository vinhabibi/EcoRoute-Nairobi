-- =====================================================================
-- EcoRoute Nairobi - PATCH for the LIVE database
-- Applies the Member 2 edits without CREATE TABLE and without sample data.
-- WARNING: step 3 REPLACES the live eco_route_pkg with the version below.
-- Run in SQL Workshop > SQL Scripts.
-- =====================================================================

-- 1. Vehicle base rates (IPCC-derived). Updates by vehicle_type, inserts if missing.
MERGE INTO vehicles v
USING (SELECT 'Delivery van' AS vehicle_type, 'Diesel' AS fuel_type, 1000 AS capacity_kg, 0.2948 AS rate FROM dual
       UNION ALL SELECT 'Light truck',  'Diesel', 3000, 0.7504 FROM dual
       UNION ALL SELECT 'Medium truck', 'Diesel', 8000, 1.0000 FROM dual) s
ON (v.vehicle_type = s.vehicle_type)
WHEN MATCHED THEN UPDATE SET v.base_kg_co2_per_km = s.rate, v.fuel_type = s.fuel_type, v.capacity_kg = s.capacity_kg
WHEN NOT MATCHED THEN INSERT (vehicle_type, fuel_type, capacity_kg, base_kg_co2_per_km)
  VALUES (s.vehicle_type, s.fuel_type, s.capacity_kg, s.rate);
COMMIT;

-- 2. Allow SHORTEST in route_results.route_type
DECLARE
  l_cond VARCHAR2(4000);
BEGIN
  FOR c IN (SELECT constraint_name, search_condition
              FROM user_constraints
             WHERE table_name = 'ROUTE_RESULTS' AND constraint_type = 'C') LOOP
    l_cond := c.search_condition;
    IF UPPER(l_cond) LIKE '%ROUTE_TYPE%' AND UPPER(l_cond) NOT LIKE '%IS NOT NULL%' THEN
      EXECUTE IMMEDIATE 'ALTER TABLE route_results DROP CONSTRAINT ' || c.constraint_name;
    END IF;
  END LOOP;
  EXECUTE IMMEDIATE 'ALTER TABLE route_results ADD CONSTRAINT route_results_ck CHECK (route_type IN (''FASTEST'',''ECO'',''SHORTEST''))';
END;
/

-- 3. Package (payload factor 0.25, SHORTEST mode)
CREATE OR REPLACE PACKAGE eco_route_pkg AS
  FUNCTION edge_co2_kg(p_length_m   NUMBER,
                       p_congestion NUMBER,
                       p_base       NUMBER,
                       p_payload    NUMBER,
                       p_capacity   NUMBER) RETURN NUMBER DETERMINISTIC;
  PROCEDURE compute_job(p_job_id NUMBER);
END eco_route_pkg;
/

CREATE OR REPLACE PACKAGE BODY eco_route_pkg AS

  TYPE t_n IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  TYPE t_s IS TABLE OF NUMBER INDEX BY VARCHAR2(20);

  -- Payload factor: +25% at full load. Matches emissions.py payload_factor.
  -- Original +50% was too aggressive; aligned with the Python engine on 2026-10-14.
  -- Congestion adds 25% per extra unit of congestion_factor.
  FUNCTION edge_co2_kg(p_length_m   NUMBER,
                       p_congestion NUMBER,
                       p_base       NUMBER,
                       p_payload    NUMBER,
                       p_capacity   NUMBER) RETURN NUMBER DETERMINISTIC IS
  BEGIN
    RETURN (p_length_m / 1000)
         * p_base
         * (1 + 0.25 * NVL(LEAST(p_payload / NULLIF(p_capacity, 0), 1), 0))
         * (1 + 0.25 * (GREATEST(p_congestion, 1) - 1));
  END edge_co2_kg;

  PROCEDURE route(p_origin   NUMBER,
                  p_dest     NUMBER,
                  p_mode     VARCHAR2,          -- 'FASTEST' | 'SHORTEST' | 'ECO'
                  p_base     NUMBER,
                  p_payload  NUMBER,
                  p_capacity NUMBER,
                  o_dist_m   OUT NUMBER,
                  o_time_s   OUT NUMBER,
                  o_co2      OUT NUMBER,
                  o_geom     OUT SDO_GEOMETRY,
                  o_found    OUT BOOLEAN) IS
    l_dist  t_s;  l_pnode t_s;  l_pedge t_s;  l_done t_s;  l_path t_n;
    u VARCHAR2(20);  k VARCHAR2(20);  v NUMBER;
    best NUMBER;  c NUMBER;  cnt PLS_INTEGER := 0;
    l_len NUMBER; l_spd NUMBER; l_cong NUMBER; l_lon NUMBER; l_lat NUMBER;
    l_ords SDO_ORDINATE_ARRAY := SDO_ORDINATE_ARRAY();
  BEGIN
    o_found := FALSE; o_dist_m := 0; o_time_s := 0; o_co2 := 0;
    l_dist(TO_CHAR(p_origin)) := 0;

    LOOP
      -- pick the unvisited node with the smallest tentative cost
      u := NULL; best := NULL; k := l_dist.FIRST;
      WHILE k IS NOT NULL LOOP
        IF NOT l_done.EXISTS(k) AND (best IS NULL OR l_dist(k) < best) THEN
          u := k; best := l_dist(k);
        END IF;
        k := l_dist.NEXT(k);
      END LOOP;
      EXIT WHEN u IS NULL OR u = TO_CHAR(p_dest);
      l_done(u) := 1;

      FOR e IN (SELECT edge_id, dst_node, length_m, speed_kph, congestion_factor
                  FROM edges WHERE src_node = TO_NUMBER(u)) LOOP
        IF NOT l_done.EXISTS(TO_CHAR(e.dst_node)) THEN
          c := best + CASE p_mode
                        WHEN 'FASTEST'  THEN
                          e.length_m / (e.speed_kph / 3.6) * e.congestion_factor
                        WHEN 'SHORTEST' THEN e.length_m
                        ELSE
                          edge_co2_kg(e.length_m, e.congestion_factor,
                                      p_base, p_payload, p_capacity)
                      END;
          IF NOT l_dist.EXISTS(TO_CHAR(e.dst_node)) OR c < l_dist(TO_CHAR(e.dst_node)) THEN
            l_dist(TO_CHAR(e.dst_node))  := c;
            l_pnode(TO_CHAR(e.dst_node)) := TO_NUMBER(u);
            l_pedge(TO_CHAR(e.dst_node)) := e.edge_id;
          END IF;
        END IF;
      END LOOP;
    END LOOP;

    IF u IS NULL OR u <> TO_CHAR(p_dest) THEN
      RETURN;   -- destination unreachable
    END IF;

    -- walk back from destination, collecting nodes and totals
    v := p_dest; cnt := 1; l_path(cnt) := v;
    WHILE v <> p_origin LOOP
      SELECT length_m, speed_kph, congestion_factor
        INTO l_len, l_spd, l_cong
        FROM edges WHERE edge_id = l_pedge(TO_CHAR(v));
      o_dist_m := o_dist_m + l_len;
      o_time_s := o_time_s + l_len / (l_spd / 3.6) * l_cong;
      o_co2    := o_co2 + edge_co2_kg(l_len, l_cong, p_base, p_payload, p_capacity);
      v := l_pnode(TO_CHAR(v));
      cnt := cnt + 1; l_path(cnt) := v;
    END LOOP;

    -- build LINESTRING origin -> destination (lon, lat order)
    FOR i IN REVERSE 1 .. cnt LOOP
      SELECT lon, lat INTO l_lon, l_lat FROM nodes WHERE node_id = l_path(i);
      l_ords.EXTEND(2);
      l_ords(l_ords.COUNT - 1) := l_lon;
      l_ords(l_ords.COUNT)     := l_lat;
    END LOOP;
    IF cnt >= 2 THEN
      o_geom := SDO_GEOMETRY(2002, 4326, NULL,
                             SDO_ELEM_INFO_ARRAY(1, 2, 1), l_ords);
    END IF;
    o_found := TRUE;
  END route;

  PROCEDURE compute_job(p_job_id NUMBER) IS
    l_job  delivery_jobs%ROWTYPE;
    l_veh  vehicles%ROWTYPE;
    l_dist NUMBER; l_time NUMBER; l_co2 NUMBER;
    l_geom SDO_GEOMETRY; l_found BOOLEAN;
  BEGIN
    SELECT * INTO l_job FROM delivery_jobs WHERE job_id = p_job_id;
    SELECT * INTO l_veh FROM vehicles WHERE vehicle_id = l_job.vehicle_id;

    DELETE FROM route_results WHERE job_id = p_job_id;

    FOR m IN (SELECT 'FASTEST'  AS route_mode FROM dual UNION ALL
              SELECT 'SHORTEST' FROM dual UNION ALL
              SELECT 'ECO'      FROM dual) LOOP
      route(l_job.origin_node, l_job.dest_node, m.route_mode,
            l_veh.base_kg_co2_per_km, l_job.payload_kg, l_veh.capacity_kg,
            l_dist, l_time, l_co2, l_geom, l_found);
      IF l_found THEN
        INSERT INTO route_results (job_id, route_type, distance_km, time_min, co2_kg, route_geom)
        VALUES (p_job_id, m.route_mode, ROUND(l_dist / 1000, 2), ROUND(l_time / 60, 1),
                ROUND(l_co2, 3), l_geom);
      END IF;
    END LOOP;
    COMMIT;
  END compute_job;

END eco_route_pkg;
/

-- 4. Dashboard view with SHORTEST columns
CREATE OR REPLACE VIEW v_job_comparison AS
SELECT j.job_id,
       v.vehicle_type,
       j.payload_kg,
       f.distance_km AS fastest_km,  f.time_min AS fastest_min,  f.co2_kg AS fastest_co2,
       e.distance_km AS eco_km,      e.time_min AS eco_min,      e.co2_kg AS eco_co2,
       f.co2_kg - e.co2_kg AS co2_saved_kg,
       ROUND(100 * (f.co2_kg - e.co2_kg) / NULLIF(f.co2_kg, 0), 1) AS co2_saved_pct,
       e.time_min - f.time_min AS extra_minutes,
       s.distance_km AS shortest_km, s.time_min AS shortest_min, s.co2_kg AS shortest_co2
  FROM delivery_jobs j
  JOIN vehicles v       ON v.vehicle_id = j.vehicle_id
  JOIN route_results f  ON f.job_id = j.job_id AND f.route_type = 'FASTEST'
  JOIN route_results e  ON e.job_id = j.job_id AND e.route_type = 'ECO'
  LEFT JOIN route_results s ON s.job_id = j.job_id AND s.route_type = 'SHORTEST';

-- 5. Check what compiled
-- SELECT object_name, object_type, status FROM user_objects WHERE object_name IN ('ECO_ROUTE_PKG','V_JOB_COMPARISON');
-- SELECT * FROM v_job_comparison;
