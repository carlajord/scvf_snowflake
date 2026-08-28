-- ============================================================================
-- Well Integrity Dashboard: Silver Layer (Dynamic Tables)
-- ============================================================================
-- Cleans, types, and standardizes the raw tables from 01_load_raw_data.sql.
-- Each Dynamic Table auto-refreshes on TARGET_LAG — no manual re-run needed.
--
-- Coordinates now come from RAW.WELLS_HYBRID (your pipeline's merged,
-- corrected coordinate file) instead of raw wells.csv — no reprojection
-- needed in Snowflake, since that was already done upstream.
--
-- Operator name comes from RAW.CLIENTS, joined on oper_id = "Client Id".
--
-- NOTE: wells_hybrid.csv's exact column names are still assumed
-- (snake_case, since it's your own pipeline's output). Run this script,
-- then DESCRIBE TABLE RAW.WELLS_HYBRID; and send me the columns if
-- anything below errors.
-- ============================================================================

USE DATABASE WELL_INTEGRITY;
CREATE SCHEMA IF NOT EXISTS SILVER;
USE WAREHOUSE COMPUTE_WH;

-- ---------------------------------------------------------------------------
-- 1. WELLS_SILVER — well registry + current operational status
-- ---------------------------------------------------------------------------
-- clients.csv can carry multiple rows per Client Id if "Client Eff Period"
-- tracks name changes oveWELL_INTEGRITY.RAW.RAW_STAGEr time — this CTE keeps only the most recent
-- record per client so the join below doesn't fan out well rows.
-- If "Client Eff Period" turns out not to be sortable as-is (e.g. it's a
-- free-text range rather than a date), this ORDER BY needs adjusting —
-- run `SELECT DISTINCT "Client Eff Period" FROM RAW.CLIENTS LIMIT 20;`
-- to check its format first.
CREATE OR REPLACE DYNAMIC TABLE WELL_INTEGRITY.SILVER.WELLS_SILVER
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
AS
WITH current_clients AS (
    SELECT
        "Client Id"::NUMBER        AS client_id,
        TRIM("Client Name")::VARCHAR AS client_name,
        TRIM("Client Abbrev")::VARCHAR AS client_abbrev
    FROM WELL_INTEGRITY.RAW.CLIENTS
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY "Client Id" ORDER BY "Client Eff Period" DESC
    ) = 1
)
SELECT
    w."wa_num"::NUMBER                       AS wa_num,
    TRIM(w.WELL_NAME)::VARCHAR               AS well_name,
    w."lat"::FLOAT                           AS latitude,
    w."lon"::FLOAT                           AS longitude,
    w."coordinate_source"::VARCHAR           AS coordinate_source,
    w."coordinate_quality"::VARCHAR          AS coordinate_quality,
    w.OPERATOR_ABBREVIATION::VARCHAR         AS oper_abbrev,
    cl.client_name                           AS operator_name,
    idx."Mode"::VARCHAR                      AS well_mode,
    idx."Fluid"::VARCHAR                     AS well_fluid,
    idx."Clas"::VARCHAR                      AS well_class,
    idx."UWI"::VARCHAR                       AS uwi,
    TRY_TO_DATE(TO_VARCHAR(idx."RR Date"), 'YYYYMMDD') AS rig_release_date
FROM WELL_INTEGRITY.RAW.WELLS_HYBRID w
LEFT JOIN WELL_INTEGRITY.RAW.WELL_INDEX idx
    ON w."wa_num"::NUMBER = idx."WA"::NUMBER
LEFT JOIN current_clients cl
    ON TRIM(w.OPERATOR_ABBREVIATION) = cl.client_abbrev
WHERE w."wa_num" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. SCVF_SILVER — integrity test reports, standardized + risk-flagged
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SILVER.SCVF_SILVER
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    s."Well Authorization Number"::NUMBER  AS wa_num,
    COALESCE(
        TRY_TO_DATE(s."Test Date"::VARCHAR, 'YYYY-MM-DD'),
        TRY_TO_DATE(s."Test Date"::VARCHAR, 'DD-MON-YYYY')
    )                                       AS test_date,
    TRIM(s."Mode Code")::VARCHAR           AS mode_code,
    TRIM(s."Operations Type")::VARCHAR     AS operations_type,
    TRIM(s."Severity")::VARCHAR            AS severity,
    TRIM(s."Flow Substance")::VARCHAR      AS flow_substance,
    s."Stabilized Buildup Pressure (kPa)"::FLOAT   AS buildup_pressure_kpa,
    s."Stabilized Gas Flow Rate (m3/d)"::FLOAT     AS gas_flow_rate_m3d,
    s."Stabilized Liquid Flow Rate (L/d)"::FLOAT / 1000.0 AS liquid_flow_rate_m3d,
    UPPER(TRIM(s."H2S Present"))::VARCHAR  AS h2s_present,
    s."H2S (ppm)"::FLOAT                   AS h2s_ppm,
    TRIM(s."Test Type")::VARCHAR           AS test_type,
    -- BC DPR Section 41: Serious SCVF = flow rate >= 300 m3/d OR H2S present
    CASE
        WHEN TRIM(s."Severity") = 'Serious' THEN TRUE
        WHEN UPPER(TRIM(s."H2S Present")) = 'Y' THEN TRUE
        WHEN s."Stabilized Gas Flow Rate (m3/d)"::FLOAT >= 300 THEN TRUE
        ELSE FALSE
    END                                     AS is_serious_scvf
FROM RAW.SCVF_REPORTS s
WHERE s."Well Authorization Number" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. CASINGS_SILVER — casing construction, with derived age
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE SILVER.CASINGS_SILVER
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    c."Wa Num"::NUMBER                     AS wa_num,
    c."Uwi"::VARCHAR                       AS uwi,
    TRIM(c."Casing Type")::VARCHAR         AS casing_type,
    c."Casing Size (mm)"::FLOAT            AS casing_size_mm,
    TRIM(c."Casing Grade Code")::VARCHAR   AS casing_grade_code,
    c."Casing Shoe Depth (m)"::FLOAT       AS casing_shoe_depth_m,
    TRIM(c."Cement Class Code")::VARCHAR   AS cement_class_code,
    c."Cement Vol (tonnes)"::FLOAT         AS cement_vol_tonnes,
    UPPER(TRIM(c."Cement Returns To Surf"))::VARCHAR AS cement_returns_to_surf,
    TRY_TO_DATE(TO_VARCHAR(c."Casing Date"), 'YYYYMMDD') AS casing_date,
    DATEDIFF(
        'year',
        TRY_TO_DATE(TO_VARCHAR(c."Casing Date"), 'YYYYMMDD'),
        CURRENT_DATE()
    )                                       AS casing_age_years,
    TRIM(c."Casing Comments")::VARCHAR     AS casing_comments
FROM RAW.CASINGS c
WHERE c."Wa Num" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 4. Sanity checks
-- ---------------------------------------------------------------------------
SELECT 'WELLS_SILVER' AS tbl, COUNT(*) AS row_count FROM SILVER.WELLS_SILVER
UNION ALL SELECT 'SCVF_SILVER', COUNT(*) FROM SILVER.SCVF_SILVER
UNION ALL SELECT 'CASINGS_SILVER', COUNT(*) FROM SILVER.CASINGS_SILVER;

-- Spot-check a few serious wells and their coordinates
SELECT wa_num, well_name, latitude, longitude, well_mode
FROM SILVER.WELLS_SILVER
WHERE wa_num IN (SELECT wa_num FROM SILVER.SCVF_SILVER WHERE is_serious_scvf)
LIMIT 10;
