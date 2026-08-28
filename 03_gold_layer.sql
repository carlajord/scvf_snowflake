-- ============================================================================
-- Well Integrity Dashboard: Gold Layer (Dynamic Table)
-- ============================================================================
-- One analytical table per well: latest SCVF status, casing condition, and
-- a 0-100 composite risk score. This is what the Streamlit app will query.
-- ============================================================================

USE DATABASE WELL_INTEGRITY;
CREATE SCHEMA IF NOT EXISTS GOLD;
USE WAREHOUSE COMPUTE_WH;

-- ---------------------------------------------------------------------------
-- 1. Latest SCVF test per well (a well can have many tests over time)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE GOLD.LATEST_SCVF_PER_WELL
    TARGET_LAG = 'DOWNSTREAM'
    WAREHOUSE = COMPUTE_WH
AS
SELECT *
FROM SILVER.SCVF_SILVER
QUALIFY ROW_NUMBER() OVER (PARTITION BY wa_num ORDER BY test_date DESC NULLS LAST) = 1;

-- Has this well EVER had a serious SCVF result (not just the latest)?
CREATE OR REPLACE DYNAMIC TABLE GOLD.SCVF_HISTORY_SUMMARY
    TARGET_LAG = 'DOWNSTREAM'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    wa_num,
    COUNT(*)                                   AS total_scvf_tests,
    MAX(IFF(is_serious_scvf, 1, 0))            AS ever_serious_scvf,
    MAX(IFF(h2s_present = 'Y', 1, 0))          AS ever_h2s_present
FROM SILVER.SCVF_SILVER
GROUP BY wa_num;

-- ---------------------------------------------------------------------------
-- 2. Casing condition summary per well
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE GOLD.CASING_SUMMARY_PER_WELL
    TARGET_LAG = 'DOWNSTREAM'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    wa_num,
    MAX(casing_age_years)                      AS oldest_casing_age_years,
    MAX(IFF(casing_type = 'SURF' AND (cement_returns_to_surf = 'N' OR REGEXP_LIKE(casing_comments, '.*(NOT? CEM\\S*|NO CMT\\S*|UNKNOWN).*', 'is')), 1, 0)) AS surface_casing_poor_cement,
    MIN(casing_grade_code)                      AS min_casing_grade_code
FROM SILVER.CASINGS_SILVER
GROUP BY wa_num
ORDER BY wa_num;

SELECT * FROM GOLD.CASING_SUMMARY_PER_WELL ORDER BY wa_num;

-- ---------------------------------------------------------------------------
-- 3. WELLS_GOLD — the table the dashboard queries
-- ---------------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE GOLD.WELLS_GOLD
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    w.wa_num,
    w.well_name,
    w.latitude,
    w.longitude,
    w.operator_name,
    w.oper_abbrev,
    w.well_mode,
    w.well_fluid,
    w.well_class,
    w.rig_release_date,

    latest.test_date                            AS latest_scvf_test_date,
    latest.severity                              AS latest_scvf_severity,
    latest.h2s_present                           AS latest_h2s_present,
    latest.gas_flow_rate_m3d                     AS latest_gas_flow_rate_m3d,
    latest.is_serious_scvf                       AS latest_is_serious_scvf,

    hist.total_scvf_tests,
    hist.ever_serious_scvf,
    hist.ever_h2s_present,

    cas.oldest_casing_age_years,
    cas.surface_casing_poor_cement,

    -- ---- Composite risk score (0-100) ----
    -- Weights are a starting point for the dashboard, not a regulatory
    -- calculation — tune them once you validate against BC DPR Section 41
    -- guidance (see bc_scvf.pdf referenced in your pipeline docs).
    LEAST(100,
        IFF(latest.is_serious_scvf, 30, 0) +
        IFF(hist.ever_h2s_present = 1, 25, 0) +
        IFF(cas.surface_casing_poor_cement = 1, 20, 0) +
        IFF(cas.oldest_casing_age_years > 30, 15, 0) +
        IFF(w.well_mode IN ('ABAN', 'SUSP'), 10, 0)
    )                                            AS risk_score,

    CASE
        WHEN LEAST(100,
            IFF(latest.is_serious_scvf, 30, 0) +
            IFF(hist.ever_h2s_present = 1, 25, 0) +
            IFF(cas.surface_casing_poor_cement = 1, 20, 0) +
            IFF(cas.oldest_casing_age_years > 30, 15, 0) +
            IFF(w.well_mode IN ('ABAN', 'SUSP'), 10, 0)
        ) >= 50 THEN 'High'
        WHEN LEAST(100,
            IFF(latest.is_serious_scvf, 30, 0) +
            IFF(hist.ever_h2s_present = 1, 25, 0) +
            IFF(cas.surface_casing_poor_cement = 1, 20, 0) +
            IFF(cas.oldest_casing_age_years > 30, 15, 0) +
            IFF(w.well_mode IN ('ABAN', 'SUSP'), 10, 0)
        ) >= 20 THEN 'Medium'
        ELSE 'Low'
    END                                          AS risk_tier

FROM SILVER.WELLS_SILVER w
LEFT JOIN GOLD.LATEST_SCVF_PER_WELL latest ON w.wa_num = latest.wa_num
LEFT JOIN GOLD.SCVF_HISTORY_SUMMARY hist   ON w.wa_num = hist.wa_num
LEFT JOIN GOLD.CASING_SUMMARY_PER_WELL cas ON w.wa_num = cas.wa_num;

-- ---------------------------------------------------------------------------
-- 4. Sanity checks
-- ---------------------------------------------------------------------------
SELECT risk_tier, COUNT(*) AS well_count
FROM GOLD.WELLS_GOLD
GROUP BY risk_tier
ORDER BY well_count DESC;

SELECT wa_num, well_name, well_mode, risk_score, risk_tier,
       latest_scvf_severity, ever_h2s_present, oldest_casing_age_years
FROM GOLD.WELLS_GOLD
ORDER BY risk_score DESC
LIMIT 10;