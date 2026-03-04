CREATE OR REPLACE TABLE GOVERNANCE__<env>.GOV_CLASSIFICATION.CLASSIFICATION_HISTORY (

    -- ══════════════════════════════════════════
    -- BUSINESS IDENTIFIERS (from Alation feed)
    -- ══════════════════════════════════════════
    DB_NAME                         STRING NOT NULL,
    SCHEMA_NAME                     STRING NOT NULL,
    TABLE_NAME                      STRING NOT NULL,
    COLUMN_NAME                     STRING NOT NULL,
    ZONE                            STRING NOT NULL,
    ENV                             STRING NOT NULL,
    SECURITY_CLASSIFICATION_CODE    STRING NOT NULL,

    -- ✅ ADD: From Alation Image 1 — missing in current design
    IS_BUSINESS_KEY                 BOOLEAN,          -- from Alation metadata
    IS_PRIMARY_KEY                  BOOLEAN,          -- from Alation metadata
    -- (scroll right in Image 1 may have more — add as needed)

    -- ══════════════════════════════════════════
    -- SCD2 TRACKING FIELDS
    -- ══════════════════════════════════════════
    SURROGATE_KEY                   STRING NOT NULL,  -- MD5(business_key || effective_from)
    BUSINESS_KEY                    STRING NOT NULL,  -- MD5(DB||SCHEMA||TABLE||COLUMN)
    HASH_DIFF                       STRING NOT NULL,  -- MD5(SECURITY_CLASSIFICATION_CODE
                                                      --     || IS_BUSINESS_KEY
                                                      --     || IS_PRIMARY_KEY)
                                                      -- ✅ EXPAND hash to cover ALL
                                                      --    Alation-sourced attributes

    EFFECTIVE_FROM                  TIMESTAMP NOT NULL,
    EFFECTIVE_TO                    TIMESTAMP NOT NULL,
    IS_CURRENT                      BOOLEAN   NOT NULL,
    CHANGE_TYPE                     STRING,           -- NEW / CHANGED / DROPPED

    -- ══════════════════════════════════════════
    -- DWH AUDIT FIELDS (align with your SCD model pattern Images 2/3)
    -- ══════════════════════════════════════════

    -- ✅ ADD: Aligns with DWH_EFFECTIVE_FROM/TO pattern in your existing models
    DWH_EFFECTIVE_FROM_TSTAMP       TIMESTAMP_LTZ,    -- mirrors EFFECTIVE_FROM (LTZ)
    DWH_EFFECTIVE_TO_TSTAMP         TIMESTAMP_LTZ,    -- mirrors EFFECTIVE_TO (LTZ)

    -- ✅ ADD: Soft delete support (consistent with fdp_party_core pattern)
    DWH_IS_DELETED_FLAG             VARCHAR(5),       -- 'TRUE' / 'FALSE'

    -- ✅ ADD: Source lineage (which Alation extract triggered this row)
    DWH_EXTRACTION_ID               STRING,

    -- ✅ ADD: Process tracking (who inserted / updated this row)
    DWH_PROCESS_INSERT_ID           STRING,
    DWH_PROCESS_UPDATE_ID           STRING,
    DWH_PROCESS_TSTAMP              TIMESTAMP_LTZ     DEFAULT LOCALTIMESTAMP,

    -- ✅ ADD: Source system tag
    DWH_SOURCE_SYSTEM_CODE          STRING            DEFAULT 'ALATION',

    -- ✅ ADD: DML type tracking (INSERT / UPDATE / DELETE from source)
    DWH_LATEST_DML_TYPE_CODE        STRING,

    -- ══════════════════════════════════════════
    -- EXISTING FIELD (keep)
    -- ══════════════════════════════════════════
    SOURCE_DS_UPDATE                TIMESTAMP,        -- Alation last update timestamp
    CREATED_AT                      TIMESTAMP         DEFAULT CURRENT_TIMESTAMP()

);

-- Clustering for performance
ALTER TABLE GOVERNANCE__<env>.GOV_CLASSIFICATION.CLASSIFICATION_HISTORY
    CLUSTER BY (IS_CURRENT, BUSINESS_KEY);

+++++++++++++
+++++++++++++++++++++
One key design note: since IS_BUSINESS_KEY and IS_PRIMARY_KEY are now tracked, your HASH_DIFF in the SCD2 model must be updated to:
sqlMD5(
    TRIM(SECURITY_CLASSIFICATION_CODE) ||
    COALESCE(IS_BUSINESS_KEY::STRING, '') ||
    COALESCE(IS_PRIMARY_KEY::STRING, '')
)
Otherwise a change to those flags won't trigger a CHANGED row.
