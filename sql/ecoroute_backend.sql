-- =====================================================================
-- EcoRoute Nairobi - Oracle APEX / Autonomous 23ai backend
-- Run in SQL Workshop > SQL Scripts (or SQL Developer Web) in order.

-- =====================================================================

-- ---------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------
CREATE TABLE nodes (
  node_id   NUMBER PRIMARY KEY,
  lat       NUMBER NOT NULL,
  lon       NUMBER NOT NULL
);

CREATE TABLE edges (
  edge_id            NUMBER PRIMARY KEY,
  src_node           NUMBER NOT NULL REFERENCES nodes(node_id),
  dst_node           NUMBER NOT NULL REFERENCES nodes(node_id),
  name               VARCHAR2(200),
  road_class         VARCHAR2(30),
  length_m           NUMBER NOT NULL,
  speed_kph          NUMBER NOT NULL,
  congestion_factor  NUMBER DEFAULT 1 NOT NULL   -- 1 = free flow, 2 = trip takes 2x as long
);
CREATE INDEX edges_src_ix ON edges(src_node);
CREATE INDEX edges_dst_ix ON edges(dst_node);

CREATE TABLE vehicles (
  vehicle_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_type        VARCHAR2(60) NOT NULL,
  fuel_type           VARCHAR2(20) NOT NULL,
  capacity_kg         NUMBER NOT NULL,
  base_kg_co2_per_km  NUMBER NOT NULL    -- empty-load baseline
);

CREATE TABLE delivery_jobs (
  job_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id   NUMBER NOT NULL REFERENCES vehicles(vehicle_id),
  origin_node  NUMBER NOT NULL REFERENCES nodes(node_id),
  dest_node    NUMBER NOT NULL REFERENCES nodes(node_id),
  payload_kg   NUMBER NOT NULL,
  created_at   TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE route_results (
  result_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id       NUMBER NOT NULL REFERENCES delivery_jobs(job_id),
  route_type   VARCHAR2(10) NOT NULL CHECK (route_type IN ('FASTEST','ECO')),
  distance_km  NUMBER,
  time_min     NUMBER,
  co2_kg       NUMBER,
  route_geom   SDO_GEOMETRY,
  CONSTRAINT route_results_uq UNIQUE (job_id, route_type)
);

-- Register geometry metadata (needed for APEX map regions / spatial index)
-- SRID 4326 is geodetic: Oracle expects full-globe bounds (-180..180, -90..90)
-- and a tolerance in metres (0.05 = 5 cm).
INSERT INTO user_sdo_geom_metadata (table_name, column_name, diminfo, srid)
VALUES ('ROUTE_RESULTS', 'ROUTE_GEOM',
        SDO_DIM_ARRAY(SDO_DIM_ELEMENT('LONGITUDE', -180, 180, 0.05),
                      SDO_DIM_ELEMENT('LATITUDE',   -90,  90, 0.05)),
        4326);
COMMIT;
-- Optional, run only AFTER route_results has rows (Oracle cannot index an empty table):
-- CREATE INDEX route_results_sx ON route_results(route_geom) INDEXTYPE IS MDSYS.SPATIAL_INDEX_V2;

-- ---------------------------------------------------------------
-- 2. SQL PROPERTY GRAPH (23ai) - topology, neighbour and reachability queries
--    If this errors with an insufficient-privileges message, ask ADMIN to run:
--      GRANT CREATE PROPERTY GRAPH TO <your_schema>;
--    Routing in section 3 does not depend on the graph, so it can be skipped.
-- ---------------------------------------------------------------
CREATE PROPERTY GRAPH nairobi_road_graph
  VERTEX TABLES (
    nodes KEY (node_id) PROPERTIES (lat, lon)
  )
  EDGE TABLES (
    edges KEY (edge_id)
      SOURCE KEY (src_node) REFERENCES nodes (node_id)
      DESTINATION KEY (dst_node) REFERENCES nodes (node_id)
      PROPERTIES (name, road_class, length_m, speed_kph, congestion_factor)
  );

-- Example: roads leaving a node
-- SELECT * FROM GRAPH_TABLE (nairobi_road_graph
--   MATCH (a IS nodes WHERE a.node_id = :P10_ORIGIN)-[e IS edges]->(b IS nodes)
--   COLUMNS (e.edge_id, e.name, b.node_id AS to_node));

-- ---------------------------------------------------------------
-- 3. EMISSION MODEL + WEIGHTED ROUTING (PL/SQL Dijkstra)
--    SQL/PGQ shortest path counts hops, not weights, so weighted
--    fastest/eco routing is done in PL/SQL over the same tables.
-- ---------------------------------------------------------------
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

  -- ASSUMPTION: load adds up to +50% fuel use at full capacity; congestion
  -- adds 25% per extra unit of congestion_factor. Replace with factors from
  -- your cited source (e.g. GLEC / DEFRA) and tune.
  FUNCTION edge_co2_kg(p_length_m   NUMBER,
                       p_congestion NUMBER,
                       p_base       NUMBER,
                       p_payload    NUMBER,
                       p_capacity   NUMBER) RETURN NUMBER DETERMINISTIC IS
  BEGIN
    RETURN (p_length_m / 1000)
         * p_base
         * (1 + 0.5  * NVL(LEAST(p_payload / NULLIF(p_capacity, 0), 1), 0))
         * (1 + 0.25 * (GREATEST(p_congestion, 1) - 1));
  END edge_co2_kg;

  PROCEDURE route(p_origin   NUMBER,
                  p_dest     NUMBER,
                  p_mode     VARCHAR2,          -- 'FASTEST' | 'ECO'
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
                        WHEN 'FASTEST' THEN
                          e.length_m / (e.speed_kph / 3.6) * e.congestion_factor
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

    FOR m IN (SELECT 'FASTEST' AS route_mode FROM dual UNION ALL SELECT 'ECO' FROM dual) LOOP
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

-- ---------------------------------------------------------------
-- 4. DASHBOARD VIEW: fastest vs eco per job
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_job_comparison AS
SELECT j.job_id,
       v.vehicle_type,
       j.payload_kg,
       f.distance_km AS fastest_km,  f.time_min AS fastest_min,  f.co2_kg AS fastest_co2,
       e.distance_km AS eco_km,      e.time_min AS eco_min,      e.co2_kg AS eco_co2,
       f.co2_kg - e.co2_kg AS co2_saved_kg,
       ROUND(100 * (f.co2_kg - e.co2_kg) / NULLIF(f.co2_kg, 0), 1) AS co2_saved_pct,
       e.time_min - f.time_min AS extra_minutes
  FROM delivery_jobs j
  JOIN vehicles v       ON v.vehicle_id = j.vehicle_id
  JOIN route_results f  ON f.job_id = j.job_id AND f.route_type = 'FASTEST'
  JOIN route_results e  ON e.job_id = j.job_id AND e.route_type = 'ECO';

-- ---------------------------------------------------------------
-- 5. SAMPLE DATA - tiny test graph where FASTEST and ECO differ
--    Path A: 1 -> 2 -> 4  (6 km, 30 kph)  shorter, slower  => ECO
--    Path B: 1 -> 3 -> 4  (8 km, 80 kph)  longer, faster   => FASTEST
-- ---------------------------------------------------------------
-- Node 1 is the CBD, node 4 is the Industrial Area side.
-- (No comments after a semicolon: the APEX script runner merges those lines.)
INSERT INTO nodes VALUES (1, -1.2864, 36.8172);
INSERT INTO nodes VALUES (2, -1.2750, 36.8350);
INSERT INTO nodes VALUES (3, -1.3050, 36.8450);
INSERT INTO nodes VALUES (4, -1.2921, 36.8600);

INSERT INTO edges VALUES (1, 1, 2, 'Local road A1', 'secondary', 3000, 30, 1);
INSERT INTO edges VALUES (2, 2, 4, 'Local road A2', 'secondary', 3000, 30, 1);
INSERT INTO edges VALUES (3, 1, 3, 'Highway B1',    'trunk',     4000, 80, 1);
INSERT INTO edges VALUES (4, 3, 4, 'Highway B2',    'trunk',     4000, 80, 1);

-- PLACEHOLDER emission factors: replace with sourced values
INSERT INTO vehicles (vehicle_type, fuel_type, capacity_kg, base_kg_co2_per_km)
VALUES ('Delivery van',  'Diesel', 1000, 0.25);
INSERT INTO vehicles (vehicle_type, fuel_type, capacity_kg, base_kg_co2_per_km)
VALUES ('Light truck',   'Diesel', 3000, 0.45);
INSERT INTO vehicles (vehicle_type, fuel_type, capacity_kg, base_kg_co2_per_km)
VALUES ('Medium truck',  'Diesel', 8000, 0.75);

INSERT INTO delivery_jobs (vehicle_id, origin_node, dest_node, payload_kg)
SELECT vehicle_id, 1, 4, 1500 FROM vehicles WHERE vehicle_type = 'Light truck';
COMMIT;

-- Compute both routes for the sample job
DECLARE
  l_job NUMBER;
BEGIN
  SELECT MAX(job_id) INTO l_job FROM delivery_jobs;
  eco_route_pkg.compute_job(l_job);
END;
/

-- Then check it in SQL Commands:
-- SELECT * FROM v_job_comparison;
