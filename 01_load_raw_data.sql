-- ============================================================================
-- Well Integrity Dashboard: Raw Data Load
-- ============================================================================
-- Loads the 6 core BCER/derived CSVs into a "raw" (bronze) schema using
-- schema inference, so table columns are read directly from each file's
-- header row instead of hand-typed.
--
-- wells_hybrid.csv (your own pipeline's merged/corrected coordinate file)
-- replaces both wells.csv and Well_Surface_Hole.csv here — it already
-- carries the best-available lat/lon plus coordinate_source and
-- coordinate_quality flags, so there's no reprojection to do in Snowflake.
--
-- PREP STEP (do this before uploading):
--   casings.csv and clients.csv each have a title line before the real
--   header row (e.g. "CASINGS FILE"). Open each file and delete that
--   first line so they become plain, single-header CSVs.
--   wells_hybrid.csv, SCVF_external_report.csv, well_index.csv, and
--   Hydrocarbon_Liquid_Analysis_Report.csv are already single-header —
--   leave those as-is.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Context — adjust to your trial account's naming
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS WELL_INTEGRITY;
CREATE SCHEMA IF NOT EXISTS WELL_INTEGRITY.RAW;
USE DATABASE WELL_INTEGRITY;
USE SCHEMA RAW;
USE WAREHOUSE COMPUTE_WH;  -- swap for your trial warehouse name if different

-- ---------------------------------------------------------------------------
-- 1. Stage — where the uploaded files land
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS RAW_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Landing zone for manually uploaded BCER CSVs';

-- ---------------------------------------------------------------------------
-- 2. File format — used both for schema inference and the actual load
-- ---------------------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_CSV_INFER
    TYPE = CSV
    PARSE_HEADER = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE = TRUE
    NULL_IF = ('', 'NULL', 'null')
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    COMMENT = 'Reads column names from row 1 of each file';

-- ---------------------------------------------------------------------------
-- 3. Upload the files
-- ---------------------------------------------------------------------------
-- Snowsight: Data > Add Data > Load files into a stage > select RAW_STAGE
-- Snowflake CLI:
--   snow stage copy wells_hybrid.csv @well_integrity.raw.raw_stage
--   snow stage copy SCVF_external_report.csv @well_integrity.raw.raw_stage
--   snow stage copy casings.csv @well_integrity.raw.raw_stage
--   snow stage copy well_index.csv @well_integrity.raw.raw_stage
--   snow stage copy clients.csv @well_integrity.raw.raw_stage
--   snow stage copy Hydrocarbon_Liquid_Analysis_Report.csv @well_integrity.raw.raw_stage
--
-- Verify they landed:
LIST @RAW_STAGE;

-- ---------------------------------------------------------------------------
-- 4. Create + load each table (schema inferred from the file's own header)
-- ---------------------------------------------------------------------------

-- 4a. wells_hybrid.csv — authoritative spatial well registry
--     (already merges Well_Surface_Hole_WGS84.csv as primary + wells.csv
--     as fallback, with coordinate_source / coordinate_quality flags)
CREATE OR REPLACE TABLE RAW.WELLS_HYBRID
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@RAW_STAGE/wells_hybrid.csv',
                FILE_FORMAT => 'RAW.FF_CSV_INFER'
            )
        )
    );

COPY INTO RAW.WELLS_HYBRID
    FROM @RAW_STAGE/wells_hybrid.csv
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_INFER')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = CONTINUE;

-- 4b. SCVF_external_report.csv — integrity test reports (critical table)
CREATE OR REPLACE TABLE RAW.SCVF_REPORTS
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@RAW_STAGE/SCVF_external_report.csv',
                FILE_FORMAT => 'RAW.FF_CSV_INFER'
            )
        )
    );

COPY INTO RAW.SCVF_REPORTS
    FROM @RAW_STAGE/SCVF_external_report.csv
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_INFER')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = CONTINUE;

-- 4c. casings.csv — casing construction (title line removed before upload)
CREATE OR REPLACE TABLE RAW.CASINGS
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@RAW_STAGE/casings.csv',
                FILE_FORMAT => 'RAW.FF_CSV_INFER'
            )
        )
    );

COPY INTO RAW.CASINGS
    FROM @RAW_STAGE/casings.csv
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_INFER')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = CONTINUE;

-- 4d. well_index.csv — operational status (Mode, Fluid, Oper)
CREATE OR REPLACE TABLE RAW.WELL_INDEX
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@RAW_STAGE/well_index.csv',
                FILE_FORMAT => 'RAW.FF_CSV_INFER'
            )
        )
    );

COPY INTO RAW.WELL_INDEX
    FROM @RAW_STAGE/well_index.csv
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_INFER')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = CONTINUE;

-- 4e. clients.csv — operator registry (title line removed before upload)
CREATE OR REPLACE TABLE RAW.CLIENTS
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@RAW_STAGE/clients.csv',
                FILE_FORMAT => 'RAW.FF_CSV_INFER'
            )
        )
    );

COPY INTO RAW.CLIENTS
    FROM @RAW_STAGE/clients.csv
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_INFER')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = CONTINUE;

-- 4f. Hydrocarbon_Liquid_Analysis_Report.csv — H2S / corrosion risk detail
CREATE OR REPLACE TABLE RAW.HYDROCARBON_LIQUID_ANALYSIS
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@RAW_STAGE/Hydrocarbon_Liquid_Analysis_Report.csv',
                FILE_FORMAT => 'RAW.FF_CSV_INFER'
            )
        )
    );

COPY INTO RAW.HYDROCARBON_LIQUID_ANALYSIS
    FROM @RAW_STAGE/Hydrocarbon_Liquid_Analysis_Report.csv
    FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_INFER')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
    ON_ERROR = CONTINUE;

-- ---------------------------------------------------------------------------
-- 5. Sanity check — row counts should roughly match the inventory doc
-- ---------------------------------------------------------------------------
-- wells_hybrid        ~39,621  (86.2% HIGH quality, 13.8% QUESTIONABLE)
-- scvf_reports        ~29,090
-- casings             ~71,841
-- well_index          ~49,026
-- clients                 730
-- hydrocarbon_liquid_analysis ~11,866
SELECT 'WELLS_HYBRID' AS table_name, COUNT(*) AS row_count FROM RAW.WELLS_HYBRID
UNION ALL SELECT 'SCVF_REPORTS', COUNT(*) FROM RAW.SCVF_REPORTS
UNION ALL SELECT 'CASINGS', COUNT(*) FROM RAW.CASINGS
UNION ALL SELECT 'WELL_INDEX', COUNT(*) FROM RAW.WELL_INDEX
UNION ALL SELECT 'CLIENTS', COUNT(*) FROM RAW.CLIENTS
UNION ALL SELECT 'HYDROCARBON_LIQUID_ANALYSIS', COUNT(*) FROM RAW.HYDROCARBON_LIQUID_ANALYSIS
ORDER BY table_name;

-- wells_hybrid.csv is your own pipeline's output, not a raw BCER export,
-- so its columns are very likely already snake_case (wa_num, latitude,
-- longitude, coordinate_source, coordinate_quality, ...) rather than the
-- "WA Num"-with-spaces style of the raw files. Confirm with:
-- DESCRIBE TABLE RAW.WELLS_HYBRID;
