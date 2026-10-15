-- EcoRoute Member 4 - views over the team's v_job_comparison (real Compute Routes results).
-- Safe to run more than once (CREATE OR REPLACE, no inserts, no deletes).
-- Needs v_job_comparison in the same schema (columns: JOB_ID, VEHICLE_TYPE, PAYLOAD_KG, FASTEST_KM,
-- FASTEST_MIN, FASTEST_CO2, ECO_KM, ECO_MIN, ECO_CO2, CO2_SAVED_KG, CO2_SAVED_PCT, EXTRA_MINUTES,
-- SHORTEST_KM, SHORTEST_MIN, SHORTEST_CO2).
-- Savings are measured against the FASTEST route (the honest comparison per the team's engine).

CREATE OR REPLACE VIEW eco_v_job_savings AS
SELECT job_id,
       'Job ' || job_id || ' - ' || vehicle_type AS job_label,
       vehicle_type,
       payload_kg,
       fastest_km,
       eco_km,
       fastest_min,
       eco_min,
       extra_minutes,
       fastest_co2   AS fastest_co2_kg,
       eco_co2       AS eco_co2_kg,
       co2_saved_kg,
       co2_saved_pct
  FROM v_job_comparison;

-- Two bars per job (FASTEST vs ECO) for a bar chart: use LABEL and VALUE columns
CREATE OR REPLACE VIEW eco_v_job_chart AS
SELECT job_id, 'Job ' || job_id || ' - ' || vehicle_type || ' (FASTEST)' AS label, fastest_co2 AS value
  FROM v_job_comparison
UNION ALL
SELECT job_id, 'Job ' || job_id || ' - ' || vehicle_type || ' (ECO)', eco_co2
  FROM v_job_comparison;

-- Headline numbers for slides
CREATE OR REPLACE VIEW eco_v_job_kpis AS
SELECT COUNT(*)                         AS jobs,
       ROUND(SUM(co2_saved_kg), 2)      AS total_co2_saved_kg,
       ROUND(AVG(co2_saved_pct), 1)     AS avg_co2_saved_pct,
       ROUND(AVG(extra_minutes), 1)     AS avg_extra_minutes
  FROM v_job_comparison;

SELECT * FROM eco_v_job_savings;
SELECT * FROM eco_v_job_kpis;
