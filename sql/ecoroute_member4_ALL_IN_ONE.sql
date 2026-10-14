-- ECO ROUTE NAIROBI - MEMBER 4 - COMBINED SCRIPT (part 1 then part 2)
-- Run ONCE as a Script (Run Script / F5), in the schema used by the APEX workspace 'ecoroute'.
-- If a table already exists error appears, tell Maria the first error message.

-- EcoRoute Nairobi - Member 4 (Emission Modeling) - Oracle APEX / Autonomous DB
-- Run in APEX > SQL Workshop > SQL Scripts. Not yet run against a live instance:
-- if anything errors, paste the message back and it can be fixed quickly.
-- ALL NUMBERS ARE EDITABLE ASSUMPTIONS. Verify against GLEC Framework / DEFRA
-- and cite the source in the SOURCE column before the pitch.
-- Prefix ECO_ keeps these tables separate from Member 2's tables.

-- 1. Fuel emission factors (kg CO2e per litre) -------------------------------
CREATE TABLE eco_emission_factors (
  fuel_type        VARCHAR2(20) PRIMARY KEY,
  kg_co2e_per_litre NUMBER(6,3) NOT NULL,
  source           VARCHAR2(200),
  notes            VARCHAR2(400)
);

INSERT INTO eco_emission_factors VALUES ('DIESEL', 2.68, 'Tank-to-wheel, typical published value - VERIFY', 'Add well-to-wheel variant if time');
INSERT INTO eco_emission_factors VALUES ('PETROL', 2.31, 'Tank-to-wheel, typical published value - VERIFY', NULL);

-- 2. Vehicle classes (fuel use empty vs fully loaded) ------------------------
CREATE TABLE eco_vehicle_classes (
  vehicle_class_id  NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  class_name        VARCHAR2(60) NOT NULL,
  fuel_type         VARCHAR2(20) NOT NULL REFERENCES eco_emission_factors(fuel_type),
  payload_cap_kg    NUMBER NOT NULL,
  l_per_100km_empty NUMBER(5,1) NOT NULL,
  l_per_100km_full  NUMBER(5,1) NOT NULL,
  source            VARCHAR2(200) DEFAULT 'Assumption - VERIFY'
);

INSERT INTO eco_vehicle_classes (class_name, fuel_type, payload_cap_kg, l_per_100km_empty, l_per_100km_full) VALUES ('Cargo motorbike (boda)', 'PETROL', 150, 2.5, 3.0);
INSERT INTO eco_vehicle_classes (class_name, fuel_type, payload_cap_kg, l_per_100km_empty, l_per_100km_full) VALUES ('Light commercial van', 'DIESEL', 1000, 9.0, 12.0);
INSERT INTO eco_vehicle_classes (class_name, fuel_type, payload_cap_kg, l_per_100km_empty, l_per_100km_full) VALUES ('Rigid truck 7.5t', 'DIESEL', 7500, 18.0, 26.0);
INSERT INTO eco_vehicle_classes (class_name, fuel_type, payload_cap_kg, l_per_100km_empty, l_per_100km_full) VALUES ('Heavy truck 20t', 'DIESEL', 20000, 24.0, 38.0);

-- 3. Speed correction: low average speed (congestion) burns more fuel per km --
CREATE TABLE eco_speed_correction (
  speed_min_kph NUMBER NOT NULL,
  speed_max_kph NUMBER NOT NULL,
  multiplier    NUMBER(4,2) NOT NULL,
  note          VARCHAR2(100)
);

INSERT INTO eco_speed_correction VALUES (0, 10, 1.60, 'Gridlock / stop-start (illustrative)');
INSERT INTO eco_speed_correction VALUES (10, 20, 1.35, 'Heavy congestion');
INSERT INTO eco_speed_correction VALUES (20, 30, 1.15, 'Slow traffic');
INSERT INTO eco_speed_correction VALUES (30, 60, 1.00, 'Efficient urban band (baseline)');
INSERT INTO eco_speed_correction VALUES (60, 80, 1.05, 'Highway');
INSERT INTO eco_speed_correction VALUES (80, 999, 1.20, 'High-speed drag');

-- 4. Sample delivery locations (approximate coordinates - Member 1 snaps to nearest graph node)
CREATE TABLE eco_locations (
  location_id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name        VARCHAR2(80) NOT NULL,
  area_type   VARCHAR2(30),
  lat         NUMBER(9,6) NOT NULL,
  lon         NUMBER(9,6) NOT NULL
);

INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Nairobi CBD', 'Commercial', -1.2864, 36.8172);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Westlands', 'Commercial', -1.2673, 36.8110);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Industrial Area', 'Industrial', -1.3070, 36.8530);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Eastleigh', 'Retail', -1.2756, 36.8506);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Kilimani', 'Residential', -1.2903, 36.7845);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Karen', 'Residential', -1.3197, 36.7073);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Roysambu (Thika Rd)', 'Residential', -1.2185, 36.8870);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Embakasi (Mombasa Rd)', 'Industrial', -1.3200, 36.9000);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Donholm', 'Residential', -1.2950, 36.8930);
INSERT INTO eco_locations (name, area_type, lat, lon) VALUES ('Gigiri', 'Commercial', -1.2330, 36.8050);

-- 5. Delivery batches and stops -----------------------------------------------
CREATE TABLE eco_batches (
  batch_id         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_name       VARCHAR2(100) NOT NULL,
  vehicle_class_id NUMBER NOT NULL REFERENCES eco_vehicle_classes(vehicle_class_id),
  depot_id         NUMBER NOT NULL REFERENCES eco_locations(location_id),
  departure_period VARCHAR2(10) DEFAULT 'OFFPEAK' CHECK (departure_period IN ('PEAK','OFFPEAK')),
  created_at       TIMESTAMP DEFAULT SYSTIMESTAMP
);

CREATE TABLE eco_batch_stops (
  stop_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_id    NUMBER NOT NULL REFERENCES eco_batches(batch_id),
  stop_order  NUMBER NOT NULL,
  location_id NUMBER NOT NULL REFERENCES eco_locations(location_id),
  drop_kg     NUMBER NOT NULL
);

-- Batch 1: van from Industrial Area to Westlands / CBD / Kilimani
INSERT INTO eco_batches (batch_name, vehicle_class_id, depot_id, departure_period)
  VALUES ('Van - Industrial Area to Westlands cluster', 2, 3, 'PEAK');
INSERT INTO eco_batch_stops (batch_id, stop_order, location_id, drop_kg) VALUES (1, 1, 1, 250);
INSERT INTO eco_batch_stops (batch_id, stop_order, location_id, drop_kg) VALUES (1, 2, 2, 300);
INSERT INTO eco_batch_stops (batch_id, stop_order, location_id, drop_kg) VALUES (1, 3, 5, 200);

-- Batch 2: truck from Embakasi along Thika Rd side
INSERT INTO eco_batches (batch_name, vehicle_class_id, depot_id, departure_period)
  VALUES ('Truck - Embakasi to Thika Rd', 3, 8, 'OFFPEAK');
INSERT INTO eco_batch_stops (batch_id, stop_order, location_id, drop_kg) VALUES (2, 1, 4, 2500);
INSERT INTO eco_batch_stops (batch_id, stop_order, location_id, drop_kg) VALUES (2, 2, 7, 3000);

COMMIT;

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

-- ===================== PART 2 =====================

-- EcoRoute Nairobi - Member 4 - PART 2 (run AFTER ecoroute_member4_apex.sql)
-- Adds: road-class speed caps, peak/off-peak speeds, route-results contract,
-- savings + scenario views that the APEX dashboard charts read from.
-- Untested on a live Oracle instance - paste back any error for a fix.

-- 1. Road-class speed caps (kph) by period. Member 1 uses these with the graph's speed_kph:
--    effective_speed = MIN(edge speed_kph, cap for its road class and period)
-- Illustrative values - tune after a quick check against real Nairobi congestion reports.
CREATE TABLE eco_road_class_speed (
  highway_class VARCHAR2(30) PRIMARY KEY,
  peak_cap_kph  NUMBER NOT NULL,
  offpeak_cap_kph NUMBER NOT NULL
);

INSERT INTO eco_road_class_speed VALUES ('MOTORWAY', 60, 80);
INSERT INTO eco_road_class_speed VALUES ('TRUNK', 25, 55);
INSERT INTO eco_road_class_speed VALUES ('PRIMARY', 20, 40);
INSERT INTO eco_road_class_speed VALUES ('SECONDARY', 18, 35);
INSERT INTO eco_road_class_speed VALUES ('TERTIARY', 15, 30);
INSERT INTO eco_road_class_speed VALUES ('RESIDENTIAL', 15, 25);
INSERT INTO eco_road_class_speed VALUES ('UNCLASSIFIED', 15, 25);
INSERT INTO eco_road_class_speed VALUES ('LIVING_STREET', 10, 15);
INSERT INTO eco_road_class_speed VALUES ('DEFAULT', 15, 25);

-- 2. Typical whole-trip average speed per period (used by scenario view)
CREATE TABLE eco_period_speed (
  period_code VARCHAR2(10) PRIMARY KEY CHECK (period_code IN ('PEAK','OFFPEAK')),
  avg_speed_kph NUMBER NOT NULL
);
INSERT INTO eco_period_speed VALUES ('PEAK', 18);
INSERT INTO eco_period_speed VALUES ('OFFPEAK', 35);

-- 3. Route results: THE CONTRACT between Member 1 (engine) and the dashboard.
--    Member 1 / Member 2 write one SHORTEST row and one ECO row per batch.
CREATE TABLE eco_route_results (
  result_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  batch_id         NUMBER NOT NULL REFERENCES eco_batches(batch_id),
  route_type       VARCHAR2(10) NOT NULL CHECK (route_type IN ('SHORTEST','ECO')),
  distance_km      NUMBER(8,3) NOT NULL,
  avg_speed_kph    NUMBER(5,1) NOT NULL,
  payload_kg       NUMBER NOT NULL,
  vehicle_class_id NUMBER NOT NULL REFERENCES eco_vehicle_classes(vehicle_class_id),
  source           VARCHAR2(20) DEFAULT 'ENGINE',   -- 'DEMO_SEED' rows must be deleted before the pitch
  created_at       TIMESTAMP DEFAULT SYSTIMESTAMP
);

-- DEMO rows so your dashboard has something to show until the engine delivers real numbers.
INSERT INTO eco_route_results (batch_id, route_type, distance_km, avg_speed_kph, payload_kg, vehicle_class_id, source) VALUES (1, 'SHORTEST', 22.0, 14, 750, 2, 'DEMO_SEED');
INSERT INTO eco_route_results (batch_id, route_type, distance_km, avg_speed_kph, payload_kg, vehicle_class_id, source) VALUES (1, 'ECO',      24.5, 32, 750, 2, 'DEMO_SEED');
INSERT INTO eco_route_results (batch_id, route_type, distance_km, avg_speed_kph, payload_kg, vehicle_class_id, source) VALUES (2, 'SHORTEST', 18.0, 22, 5500, 3, 'DEMO_SEED');
INSERT INTO eco_route_results (batch_id, route_type, distance_km, avg_speed_kph, payload_kg, vehicle_class_id, source) VALUES (2, 'ECO',      19.2, 38, 5500, 3, 'DEMO_SEED');
COMMIT;

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

-- Check: SELECT * FROM eco_v_savings;  SELECT * FROM eco_v_sanity_checks2;

-- ===================== FINAL CHECKS =====================
SELECT * FROM eco_v_sanity_checks;
SELECT * FROM eco_v_savings;
SELECT * FROM eco_v_sanity_checks2;
