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

        -- Detect if the very first event for this key is a DELETE.
        -- If TRUE, target has a phantom INSERT row (inserted before the landing
        -- table started capturing), so we offset target_record_order by +1.
        CASE
            WHEN FIRST_VALUE(is_delete_event) OVER (
                     PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                                  RELATIONSHIP_CODE, CUSTOMER2_NO
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
                 ) = TRUE
            THEN 1
            ELSE 0
        END                                                             AS first_event_is_delete_offset,

        -- target_record_order: counts only non-DELETE source rows + phantom offset.
        -- This keeps source row numbering aligned with target's physical row numbering,
        -- because DELETE events update an existing target row rather than insert a new one.
        SUM(CASE WHEN is_delete_event = FALSE THEN 1 ELSE 0 END) OVER (
            PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                         RELATIONSHIP_CODE, CUSTOMER2_NO
            ORDER BY metadata_time ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
        +
        CASE
            WHEN FIRST_VALUE(is_delete_event) OVER (
                     PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                                  RELATIONSHIP_CODE, CUSTOMER2_NO
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
                 ) = TRUE
            THEN 1
            ELSE 0
        END                                                             AS target_record_order,

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
            WHEN is_delete_event = TRUE  THEN 'DELETE'
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE,
                                  RELATIONSHIP_CODE, CUSTOMER2_NO
                     ORDER BY metadata_time ASC
                 ) = 1               THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                             AS scenario

    FROM source_dedup
),

-- Use TRIM(RELATIONSHIP_CODE) explicitly in PARTITION BY of ROW_NUMBER()
-- because window functions in the same SELECT cannot reference aliases
-- defined in that same SELECT list.
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
                         TRIM(RELATIONSHIP_CODE),
                         CUSTOMER2_NO
            ORDER BY dwh_effective_from_tstamp ASC
        )                                                               AS record_order
    FROM cust__raw__dev.bis.bst_cust_reln
    WHERE CUSTOMER1_NO      IN ('69470009', '38689016')
      AND CUSTOMER2_NO      IN ('4454956', '251000')
      AND RELATIONSHIP_TYPE IN ('FB', 'FD')
      AND TRIM(RELATIONSHIP_CODE) IN ('CTL', 'DIR', 'EXE')
),

-- Verifies every INSERT and UPDATE source row exists in target
-- with matching effective_from and effective_to timestamps.
-- Uses target_record_order so row numbering stays aligned with
-- how target physically stores rows (DELETEs don't add new rows).
insert_update_check AS (
    SELECT
        e.CUSTOMER1_NO,
        e.RELATIONSHIP_TYPE,
        e.RELATIONSHIP_CODE,
        e.CUSTOMER2_NO,
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp,
        t.dwh_effective_to_tstamp,
        CASE
            WHEN t.CUSTOMER1_NO IS NULL
                THEN 'FAIL'   -- row missing in target
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL'   -- effective_from mismatch
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp
                THEN 'FAIL'   -- effective_to mismatch
            ELSE 'PASS'
        END                                                             AS row_result
    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO      = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = t.CUSTOMER2_NO
        AND e.target_record_order = t.record_order   -- aligned row numbering
    WHERE e.scenario IN ('INSERT', 'UPDATE')
),

-- Verifies every DELETE source event maps to the correct target row:
-- the target row at target_record_order should be flagged D/Y
-- and have matching effective_from and effective_to timestamps.
-- DELETE in source updates an existing target row (same target_record_order),
-- it does NOT create a new row.
delete_check AS (
    SELECT
        e.CUSTOMER1_NO,
        e.RELATIONSHIP_TYPE,
        e.RELATIONSHIP_CODE,
        e.CUSTOMER2_NO,
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp,
        t.dwh_effective_to_tstamp,
        CASE
            WHEN t.CUSTOMER1_NO IS NULL
                THEN 'FAIL'   -- target row not found
            WHEN t.dwh_is_deleted_flag IS DISTINCT FROM 'Y'
                THEN 'FAIL'   -- deleted flag not set to Y
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL'   -- DML type code not set to D
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL'   -- effective_from mismatch
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp
                THEN 'FAIL'   -- effective_to mismatch
            ELSE 'PASS'
        END                                                             AS row_result
    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO        = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE   = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE   = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO        = t.CUSTOMER2_NO
        AND e.target_record_order = t.record_order   -- DELETE maps to same target row
    WHERE e.scenario = 'DELETE'
),

-- Verifies that when a late-arriving event lands between two existing target rows,
-- the PRIOR target row's effective_to was correctly back-dated to
-- (late_arrival_effective_from - 1 microsecond).
-- Without this check, the prior row stays open at 9999-12-31 causing an overlap.
-- Uses (target_record_order - 1) to fetch the prior target row.
missing_late_check AS (
    SELECT
        e.CUSTOMER1_NO,
        e.RELATIONSHIP_TYPE,
        e.RELATIONSHIP_CODE,
        e.CUSTOMER2_NO,
        e.record_order,
        'LATE_PRIOR_ROW_BACKDATE'                                       AS scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        prev_t.dwh_effective_from_tstamp,
        prev_t.dwh_effective_to_tstamp,
        TIMESTAMPADD(
            MICROSECOND, -1, e.exp_effective_from
        )                                                               AS expected_prior_effective_to,
        CASE
            WHEN prev_t.CUSTOMER1_NO IS NULL
                THEN 'FAIL'   -- prior target row not found
            WHEN prev_t.dwh_effective_to_tstamp IS DISTINCT FROM
                 TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)
                THEN 'FAIL'   -- prior row not back-dated correctly
            ELSE 'PASS'
        END                                                             AS row_result
    FROM source_expected e
    LEFT JOIN target_data prev_t
        ON  e.CUSTOMER1_NO                  = prev_t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE             = prev_t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE             = prev_t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO                  = prev_t.CUSTOMER2_NO
        AND (e.target_record_order - 1)     = prev_t.record_order   -- prior target row
    WHERE e.is_late_arrival = TRUE
      AND e.scenario <> 'DELETE'
)

-- Final union: insert_update_check has 10 columns, delete_check has 10 columns.
-- missing_late_check has 11 columns (extra: expected_prior_effective_to).
-- Add NULL placeholder in insert_update_check and delete_check to match column count.
SELECT
    CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO,
    record_order, scenario,
    exp_effective_from, exp_effective_to,
    dwh_effective_from_tstamp, dwh_effective_to_tstamp,
    NULL AS expected_prior_effective_to,
    row_result
FROM insert_update_check

UNION ALL

SELECT
    CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO,
    record_order, scenario,
    exp_effective_from, exp_effective_to,
    dwh_effective_from_tstamp, dwh_effective_to_tstamp,
    NULL AS expected_prior_effective_to,
    row_result
FROM delete_check

UNION ALL

SELECT
    CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO,
    record_order, scenario,
    exp_effective_from, exp_effective_to,
    dwh_effective_from_tstamp, dwh_effective_to_tstamp,
    expected_prior_effective_to,
    row_result
FROM missing_late_check

ORDER BY
    CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO,
    record_order, scenario
;
