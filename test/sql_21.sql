WITH source_raw AS (
    SELECT
        IFF(
            TYPEOF(RECORD_CONTENT:afterState) = 'NULL_VALUE',
            RECORD_CONTENT:beforeState:CUSTOMER1_NO,
            RECORD_CONTENT:afterState:CUSTOMER1_NO
        )::NUMBER                                                       AS CUSTOMER1_NO,

        TRIM(IFF(
            TYPEOF(RECORD_CONTENT:afterState) = 'NULL_VALUE',
            RECORD_CONTENT:beforeState:RELATIONSHIP_TYPE,
            RECORD_CONTENT:afterState:RELATIONSHIP_TYPE
        )::VARCHAR, '"')                                                AS RELATIONSHIP_TYPE,

        TRIM(TRIM(IFF(
            TYPEOF(RECORD_CONTENT:afterState) = 'NULL_VALUE',
            RECORD_CONTENT:beforeState:RELATIONSHIP_CODE,
            RECORD_CONTENT:afterState:RELATIONSHIP_CODE
        )::VARCHAR, '"'))                                               AS RELATIONSHIP_CODE,

        IFF(
            TYPEOF(RECORD_CONTENT:afterState) = 'NULL_VALUE',
            RECORD_CONTENT:beforeState:CUSTOMER2_NO,
            RECORD_CONTENT:afterState:CUSTOMER2_NO
        )::NUMBER                                                       AS CUSTOMER2_NO,

        RECORD_CONTENT:metadata:time::TIMESTAMP_NTZ                    AS metadata_time,

        CASE
            WHEN TYPEOF(RECORD_CONTENT:afterState) = 'NULL_VALUE'
             AND TYPEOF(RECORD_CONTENT:beforeState) = 'OBJECT'
            THEN TRUE
            ELSE FALSE
        END                                                             AS is_delete_event

    FROM landing__dev.bis.BST_CUST_RELN
    WHERE
        COALESCE(
            RECORD_CONTENT:afterState:CUSTOMER1_NO,
            RECORD_CONTENT:beforeState:CUSTOMER1_NO
        ) IN ('69470009', '38689016')
        AND COALESCE(
            RECORD_CONTENT:afterState:CUSTOMER2_NO,
            RECORD_CONTENT:beforeState:CUSTOMER2_NO
        ) IN ('4454956', '251000')
        AND TRIM(TRIM(IFF(
            TYPEOF(RECORD_CONTENT:afterState) = 'NULL_VALUE',
            RECORD_CONTENT:beforeState:RELATIONSHIP_CODE,
            RECORD_CONTENT:afterState:RELATIONSHIP_CODE
        )::VARCHAR, '"')) IN ('CTL', 'DIR', 'EXE')
        AND TRIM(IFF(
            TYPEOF(RECORD_CONTENT:afterState) = 'NULL_VALUE',
            RECORD_CONTENT:beforeState:RELATIONSHIP_TYPE,
            RECORD_CONTENT:afterState:RELATIONSHIP_TYPE
        )::VARCHAR, '"') IN ('FB', 'FD')
),

source_dedup AS (
    SELECT DISTINCT
        CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE,
        CUSTOMER2_NO, metadata_time, is_delete_event
    FROM source_raw
),

source_expected AS (
    SELECT
        CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO,
        metadata_time                                                   AS exp_effective_from,

        TIMESTAMPADD(
            MICROSECOND, -1,
            COALESCE(
                LEAD(metadata_time) OVER (
                    PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                                 RELATIONSHIP_CODE, CUSTOMER2_NO
                    ORDER BY metadata_time ASC
                ),
                '9999-12-31T00:00:00.000001'::TIMESTAMP_NTZ
            )
        )                                                               AS exp_effective_to,

        ROW_NUMBER() OVER (
            PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                         RELATIONSHIP_CODE, CUSTOMER2_NO
            ORDER BY metadata_time ASC
        )                                                               AS record_order,

        is_delete_event,

        CASE
            WHEN metadata_time < MAX(metadata_time) OVER (
                     PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                                  RELATIONSHIP_CODE, CUSTOMER2_NO
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 )
            THEN TRUE
            ELSE FALSE
        END                                                             AS is_late_arrival,

        CASE
            WHEN is_delete_event = TRUE THEN 'DELETE'
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                                  RELATIONSHIP_CODE, CUSTOMER2_NO
                     ORDER BY metadata_time ASC
                 ) = 1              THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                             AS scenario

    FROM source_dedup
),

-- FIX 1: Use TRIM(RELATIONSHIP_CODE) explicitly in the PARTITION BY of ROW_NUMBER()
--        to avoid window function referencing the untrimmed column when alias
--        is not yet resolved in the same SELECT scope.
target_data AS (
    SELECT
        CUSTOMER1_NO,
        RELATIONSHIP_TYPE,
        TRIM(RELATIONSHIP_CODE)                                         AS RELATIONSHIP_CODE,
        CUSTOMER2_NO,
        dwh_effective_from_tstamp,
        dwh_effective_to_tstamp,
        dwh_latest_dml_type_code,
        dwh_is_deleted_flag,
        ROW_NUMBER() OVER (
            PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                         TRIM(RELATIONSHIP_CODE),   -- explicit TRIM here (alias not usable in same SELECT)
                         CUSTOMER2_NO
            ORDER BY dwh_effective_from_tstamp ASC
        )                                                               AS record_order
    FROM cust__raw__dev.bis.bst_cust_reln
    WHERE CUSTOMER1_NO    IN ('69470009', '38689016')
      AND CUSTOMER2_NO    IN ('4454956', '251000')
      AND RELATIONSHIP_TYPE IN ('FB', 'FD')
      AND TRIM(RELATIONSHIP_CODE) IN ('CTL', 'DIR', 'EXE')
),

-- Checks INSERT and UPDATE scenarios:
-- Verifies effective_from and effective_to timestamps match between source and target.
insert_update_check AS (
    SELECT
        e.CUSTOMER1_NO, e.RELATIONSHIP_TYPE, e.RELATIONSHIP_CODE, e.CUSTOMER2_NO,
        e.record_order, e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp,
        t.dwh_effective_to_tstamp,
        CASE
            WHEN t.CUSTOMER1_NO IS NULL                              THEN 'FAIL'  -- row missing in target
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp THEN 'FAIL'  -- effective_from mismatch
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp   THEN 'FAIL'  -- effective_to mismatch
            ELSE 'PASS'
        END                                                             AS row_result
    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO      = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = t.CUSTOMER2_NO
        AND e.record_order      = t.record_order
    WHERE e.scenario IN ('INSERT', 'UPDATE')
),

-- FIX 2: DELETE events in source are their own numbered row (record_order N),
--        but in the target the delete is represented as an update to the PREVIOUS
--        row (record_order N-1). Join on (e.record_order - 1) to match correctly.
--        Also verify dwh_is_deleted_flag = 'Y' and dwh_latest_dml_type_code = 'D'.
delete_check AS (
    SELECT
        e.CUSTOMER1_NO, e.RELATIONSHIP_TYPE, e.RELATIONSHIP_CODE, e.CUSTOMER2_NO,
        e.record_order, e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp,
        t.dwh_effective_to_tstamp,
        CASE
            WHEN t.CUSTOMER1_NO IS NULL                              THEN 'FAIL'  -- matching target row not found
            WHEN t.dwh_is_deleted_flag IS DISTINCT FROM 'Y'         THEN 'FAIL'  -- deleted flag not set
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'    THEN 'FAIL'  -- DML type not 'D'
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp THEN 'FAIL'  -- effective_from mismatch
            ELSE 'PASS'
        END                                                             AS row_result
    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO      = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = t.CUSTOMER2_NO
        AND (e.record_order - 1) = t.record_order  -- FIX: DELETE source row N maps to target row N-1
    WHERE e.scenario = 'DELETE'
),

-- FIX 3: Late arrivals must also verify that the PRIOR target row's effective_to
--        was retroactively adjusted to (late_arrival_effective_from - 1 microsecond).
--        Without this check a late arrival might land correctly but the preceding
--        row's open-ended effective_to is never closed, leaving a gap/overlap.
missing_late_check AS (
    SELECT
        e.CUSTOMER1_NO, e.RELATIONSHIP_TYPE, e.RELATIONSHIP_CODE, e.CUSTOMER2_NO,
        e.record_order, e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp,
        t.dwh_effective_to_tstamp,
        CASE
            WHEN t.CUSTOMER1_NO IS NULL                              THEN 'FAIL'  -- late arrival row missing in target
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp THEN 'FAIL'  -- effective_from mismatch
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp   THEN 'FAIL'  -- effective_to mismatch
            -- Verify the prior row's effective_to was retroactively corrected to
            -- (this row's effective_from - 1 microsecond)
            WHEN prev_t.dwh_effective_to_tstamp IS DISTINCT FROM
                 TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)   THEN 'FAIL'  -- prior row not back-dated
            ELSE 'PASS'
        END                                                             AS row_result
    FROM source_expected e
    -- Join to the late arrival's own target row
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO      = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = t.CUSTOMER2_NO
        AND e.record_order      = t.record_order
    -- Join to the PREVIOUS target row to verify its effective_to was back-dated
    LEFT JOIN target_data prev_t
        ON  e.CUSTOMER1_NO      = prev_t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = prev_t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = prev_t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = prev_t.CUSTOMER2_NO
        AND (e.record_order - 1) = prev_t.record_order  -- prior row
    WHERE e.is_late_arrival = TRUE
      AND e.scenario != 'DELETE'
)

SELECT * FROM insert_update_check
UNION ALL
SELECT * FROM delete_check
UNION ALL
SELECT * FROM missing_late_check
;
