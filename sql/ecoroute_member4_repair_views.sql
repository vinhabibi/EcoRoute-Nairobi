-- EcoRoute Member 4 - REPAIR SCRIPT (safe to re-run: functions/views use CREATE OR REPLACE, no inserts, no table creates)
-- Run only if a page says 'table or view does not exist' for an ECO_V_* view or ECO_CALC_CO2E.

-- 6. Core calculation (APEX pages call this; Member 1 mirrors it in Python) ---
CREATE OR REPLACE FUNCTION eco_calc_co2e (
  p_distance_km     IN NUMBER,
  p_payload_kg      IN NUMBER,
  p_vehicle_class_id IN NUMBER,
  p_avg_speed_kph   IN NUMBER DEFAULT 40
) RETURN NUMBER IS
  v_cap   NUMBER; v_empty NUMBER; v_full NUMBER; v_ef NUMBER;
  v_mult  NUMBER := 1;
  v_load  NUMBER; v_litres NUMBER;
BEGIN
  SELECT c.payload_cap_kg, c.l_per_100km_empty, c.l_per_100km_full, f.kg_co2e_per_litre
    INTO v_cap, v_empty, v_full, v_ef
    FROM eco_vehicle_classes c JOIN eco_emission_factors f ON f.fuel_type = c.fuel_type
   WHERE c.vehicle_class_id = p_vehicle_class_id;

  BEGIN
    SELECT multiplier INTO v_mult FROM eco_speed_correction
     WHERE p_avg_speed_kph >= speed_min_kph AND p_avg_speed_kph < speed_max_kph;
  EXCEPTION WHEN NO_DATA_FOUND THEN v_mult := 1;
  END;

  v_load   := LEAST(GREATEST(p_payload_kg / v_cap, 0), 1);
  v_litres := p_distance_km * (v_empty + (v_full - v_empty) * v_load) / 100 * v_mult;
  RETURN ROUND(v_litres * v_ef, 3);   -- kg CO2e
END eco_calc_co2e;
/

-- 7. Validation view: sanity-check outputs before the demo ---------------------
CREATE OR REPLACE VIEW eco_v_sanity_checks AS
SELECT 'Empty van 10km < full van 10km' AS test_name,
       eco_calc_co2e(10, 0, 2, 40)    AS value_a,
       eco_calc_co2e(10, 1000, 2, 40) AS value_b,
       CASE WHEN eco_calc_co2e(10, 0, 2, 40) < eco_calc_co2e(10, 1000, 2, 40) THEN 'PASS' ELSE 'FAIL' END AS result
FROM dual
UNION ALL
SELECT 'Congested (8kph) > free flow (40kph)',
       eco_calc_co2e(10, 500, 2, 8), eco_calc_co2e(10, 500, 2, 40),
       CASE WHEN eco_calc_co2e(10, 500, 2, 8) > eco_calc_co2e(10, 500, 2, 40) THEN 'PASS' ELSE 'FAIL' END
FROM dual
UNION ALL
SELECT 'Truck > van, same trip',
       eco_calc_co2e(10, 1000, 3, 40), eco_calc_co2e(10, 1000, 2, 40),
       CASE WHEN eco_calc_co2e(10, 1000, 3, 40) > eco_calc_co2e(10, 1000, 2, 40) THEN 'PASS' ELSE 'FAIL' END
FROM dual
UNION ALL
SELECT 'Zero distance = zero CO2e',
       eco_calc_co2e(0, 500, 2, 40), 0,
       CASE WHEN eco_calc_co2e(0, 500, 2, 40) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM dual;

-- Quick check: SELECT * FROM eco_v_sanity_checks;

-- 4. Latest result per batch/route type, with CO2e and litres of fuel
CREATE OR REPLACE VIEW eco_v_route_emissions AS
SELECT r.batch_id, b.batch_name, r.route_type, r.distance_km, r.avg_speed_kph,
       r.payload_kg, vc.class_name, r.source,
       eco_calc_co2e(r.distance_km, r.payload_kg, r.vehicle_class_id, r.avg_speed_kph) AS co2e_kg,
       ROUND(eco_calc_co2e(r.distance_km, r.payload_kg, r.vehicle_class_id, r.avg_speed_kph)
             / ef.kg_co2e_per_litre, 3) AS fuel_litres
  FROM (SELECT x.*, ROW_NUMBER() OVER (PARTITION BY batch_id, route_type ORDER BY created_at DESC, result_id DESC) rn
          FROM eco_route_results x) r
  JOIN eco_batches b ON b.batch_id = r.batch_id
  JOIN eco_vehicle_classes vc ON vc.vehicle_class_id = r.vehicle_class_id
  JOIN eco_emission_factors ef ON ef.fuel_type = vc.fuel_type
 WHERE r.rn = 1;

-- 5. Savings: shortest vs eco per batch (feeds the headline KPI cards and bar chart)
CREATE OR REPLACE VIEW eco_v_savings AS
SELECT batch_id, batch_name,
       MAX(CASE WHEN route_type = 'SHORTEST' THEN co2e_kg END)    AS shortest_co2e_kg,
       MAX(CASE WHEN route_type = 'ECO' THEN co2e_kg END)         AS eco_co2e_kg,
       MAX(CASE WHEN route_type = 'SHORTEST' THEN fuel_litres END) AS shortest_litres,
       MAX(CASE WHEN route_type = 'ECO' THEN fuel_litres END)      AS eco_litres,
       MAX(CASE WHEN route_type = 'SHORTEST' THEN distance_km END) AS shortest_km,
       MAX(CASE WHEN route_type = 'ECO' THEN distance_km END)      AS eco_km,
       MAX(CASE WHEN route_type = 'SHORTEST' THEN co2e_kg END)
         - MAX(CASE WHEN route_type = 'ECO' THEN co2e_kg END)      AS co2e_saved_kg,
       ROUND(100 * (MAX(CASE WHEN route_type = 'SHORTEST' THEN co2e_kg END)
                  - MAX(CASE WHEN route_type = 'ECO' THEN co2e_kg END))
             / NULLIF(MAX(CASE WHEN route_type = 'SHORTEST' THEN co2e_kg END), 0), 1) AS co2e_saved_pct,
       MAX(CASE WHEN route_type = 'SHORTEST' THEN fuel_litres END)
         - MAX(CASE WHEN route_type = 'ECO' THEN fuel_litres END)  AS litres_saved
  FROM eco_v_route_emissions
 GROUP BY batch_id, batch_name;

-- 6. Scenarios: same batch, every vehicle class that can carry it, peak vs off-peak
--    (uses the SHORTEST distance as the baseline trip)
CREATE OR REPLACE VIEW eco_v_scenarios AS
SELECT b.batch_id, b.batch_name, vc.class_name, ps.period_code, ps.avg_speed_kph,
       pl.total_kg,
       ROUND(eco_calc_co2e(rr.distance_km, pl.total_kg, vc.vehicle_class_id, ps.avg_speed_kph), 2) AS co2e_kg
  FROM eco_batches b
  JOIN (SELECT batch_id, SUM(drop_kg) AS total_kg FROM eco_batch_stops GROUP BY batch_id) pl
    ON pl.batch_id = b.batch_id
  JOIN eco_v_route_emissions rr ON rr.batch_id = b.batch_id AND rr.route_type = 'SHORTEST'
  CROSS JOIN eco_vehicle_classes vc
  CROSS JOIN eco_period_speed ps
 WHERE pl.total_kg <= vc.payload_cap_kg;   -- exclude vehicles that cannot carry the load

-- 7. Extra validation tests
CREATE OR REPLACE VIEW eco_v_sanity_checks2 AS
SELECT 'ECO route never worse than SHORTEST (demo batches)' AS test_name,
       NVL(MIN(co2e_saved_kg), 0) AS value_a, 0 AS value_b,
       CASE WHEN NVL(MIN(co2e_saved_kg), 0) >= 0 THEN 'PASS' ELSE 'REVIEW' END AS result
  FROM eco_v_savings
UNION ALL
SELECT 'No DEMO_SEED rows left (must PASS before submission)',
       COUNT(*), 0, CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'REMOVE DEMO' END
  FROM eco_route_results WHERE source = 'DEMO_SEED'
UNION ALL
SELECT 'Every batch has both SHORTEST and ECO result',
       COUNT(*), (SELECT COUNT(*) FROM eco_batches),
       CASE WHEN COUNT(*) = (SELECT COUNT(*) FROM eco_batches) THEN 'PASS' ELSE 'MISSING' END
  FROM eco_v_savings WHERE shortest_co2e_kg IS NOT NULL AND eco_co2e_kg IS NOT NULL;


SELECT object_name, object_type, status FROM user_objects WHERE object_name LIKE 'ECO%' ORDER BY object_type, object_name;
