WITH source_raw AS (
    SELECT
        COALESCE(
            RECORD_CONTENT:afterState:CUSTOMER1_NO,
            RECORD_CONTENT:beforeState:CUSTOMER1_NO
        )                                                               AS CUSTOMER1_NO,

        COALESCE(
            RECORD_CONTENT:afterState:RELATIONSHIP_TYPE,
            RECORD_CONTENT:beforeState:RELATIONSHIP_TYPE
        )                                                               AS RELATIONSHIP_TYPE,

        COALESCE(
            RECORD_CONTENT:afterState:RELATIONSHIP_CODE,
            RECORD_CONTENT:beforeState:RELATIONSHIP_CODE
        )                                                               AS RELATIONSHIP_CODE,

        COALESCE(
            RECORD_CONTENT:afterState:CUSTOMER2_NO,
            RECORD_CONTENT:beforeState:CUSTOMER2_NO
        )                                                               AS CUSTOMER2_NO,

        RECORD_CONTENT:metadata:time::TIMESTAMP_NTZ                    AS metadata_time,

        -- DELETE detection: afterState is null, beforeState is populated
        CASE
            WHEN RECORD_CONTENT:afterState IS NULL
             AND RECORD_CONTENT:beforeState IS NOT NULL
            THEN TRUE
            ELSE FALSE
        END                                                             AS is_delete_event

    FROM landing__dev.bis.BST_CUST_RELN
),

source_dedup AS (
    SELECT DISTINCT
        CUSTOMER1_NO,
        RELATIONSHIP_TYPE,
        RELATIONSHIP_CODE,
        CUSTOMER2_NO,
        metadata_time,
        is_delete_event
    FROM source_raw
),

source_expected AS (
    SELECT
        CUSTOMER1_NO,
        RELATIONSHIP_TYPE,
        RELATIONSHIP_CODE,
        CUSTOMER2_NO,
        metadata_time                                                   AS exp_effective_from,

        TIMESTAMPADD(
            MICROSECOND, -1,
            COALESCE(
                LEAD(metadata_time) OVER (
                    PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO
                    ORDER BY metadata_time ASC
                ),
                '9999-12-31T00:00:00.000001'::TIMESTAMP_NTZ
            )
        )                                                               AS exp_effective_to,

        ROW_NUMBER() OVER (
            PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO
            ORDER BY metadata_time ASC
        )                                                               AS record_order,

        is_delete_event,

        -- MISSING LATE RECORD detection:
        -- a record whose metadata_time is LESS THAN the max metadata_time
        -- already seen in prior rows of the same partition (i.e. it arrived
        -- out of order relative to business event time ordering)
        CASE
            WHEN metadata_time < MAX(metadata_time) OVER (
                     PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 )
            THEN TRUE
            ELSE FALSE
        END                                                             AS is_late_arrival,

        CASE
            WHEN is_delete_event = TRUE THEN 'DELETE'
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO
                     ORDER BY metadata_time ASC
                 ) = 1
            THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                             AS scenario

    FROM source_dedup
),

target_data AS (
    SELECT
        CUSTOMER1_NO,
        RELATIONSHIP_TYPE,
        RELATIONSHIP_CODE,
        CUSTOMER2_NO,
        dwh_effective_from_tstamp,
        dwh_effective_to_tstamp,
        dwh_latest_dml_type_code,
        dwh_is_deleted_flag,
        ROW_NUMBER() OVER (
            PARTITION BY CUSTOMER1_NO, RELATIONSHIP_TYPE, RELATIONSHIP_CODE, CUSTOMER2_NO
            ORDER BY dwh_effective_from_tstamp ASC
        )                                                               AS record_order
    FROM cust__raw__dev.bis.bst_cust_reln
),

-- ── 1) INSERT / UPDATE (excludes delete events)
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
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        t.dwh_latest_dml_type_code,
        t.dwh_is_deleted_flag,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'FAIL'
             ELSE 'PASS' END                                            AS chk_row_exists,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'N/A'
             WHEN e.exp_effective_from = t.dwh_effective_from_tstamp THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_effective_from,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'N/A'
             WHEN e.exp_effective_to = t.dwh_effective_to_tstamp THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_effective_to,

        'N/A'                                                           AS chk_deleted_flag,
        'N/A'                                                           AS chk_dml_type,

        CASE
            WHEN t.CUSTOMER1_NO IS NULL
                THEN 'FAIL - Row missing in target for record_order ' || e.record_order::VARCHAR
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL - effective_from mismatch (exp: ' || e.exp_effective_from::VARCHAR
                     || ', act: ' || t.dwh_effective_from_tstamp::VARCHAR || ')'
            WHEN e.exp_effective_to <> t.dwh_effective_to_tstamp
                THEN 'FAIL - effective_to mismatch (exp: ' || e.exp_effective_to::VARCHAR
                     || ', act: ' || t.dwh_effective_to_tstamp::VARCHAR || ')'
            ELSE 'PASS'
        END                                                             AS final_result,

        'INSERT_UPDATE'                                                 AS check_type

    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO      = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = t.CUSTOMER2_NO
        AND e.record_order      = t.record_order
    WHERE e.scenario IN ('INSERT', 'UPDATE')
),

-- ── 2) MISSING LATE RECORD
-- Source has a record whose metadata_time sits between two already-loaded
-- target rows — target should have split an existing window to accommodate
-- it. We check: does a target row exist at this record_order position?
-- If yes, were effective_from / effective_to correctly adjusted?
missing_late_check AS (
    SELECT
        e.CUSTOMER1_NO,
        e.RELATIONSHIP_TYPE,
        e.RELATIONSHIP_CODE,
        e.CUSTOMER2_NO,
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        t.dwh_latest_dml_type_code,
        t.dwh_is_deleted_flag,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'FAIL'
             ELSE 'PASS' END                                            AS chk_row_exists,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'N/A'
             WHEN e.exp_effective_from = t.dwh_effective_from_tstamp THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_effective_from,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'N/A'
             WHEN e.exp_effective_to = t.dwh_effective_to_tstamp THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_effective_to,

        'N/A'                                                           AS chk_deleted_flag,
        'N/A'                                                           AS chk_dml_type,

        CASE
            WHEN t.CUSTOMER1_NO IS NULL
                THEN 'FAIL - Late record not reflected in target (record_order '
                     || e.record_order::VARCHAR
                     || ', metadata_time: ' || e.exp_effective_from::VARCHAR || ')'
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL - Late record effective_from mismatch (exp: '
                     || e.exp_effective_from::VARCHAR
                     || ', act: ' || t.dwh_effective_from_tstamp::VARCHAR || ')'
            WHEN e.exp_effective_to <> t.dwh_effective_to_tstamp
                THEN 'FAIL - Late record effective_to mismatch after window split (exp: '
                     || e.exp_effective_to::VARCHAR
                     || ', act: ' || t.dwh_effective_to_tstamp::VARCHAR || ')'
            ELSE 'PASS'
        END                                                             AS final_result,

        'MISSING_LATE_RECORD'                                           AS check_type

    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO      = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = t.CUSTOMER2_NO
        AND e.record_order      = t.record_order
    -- only fire for late arrivals that are not delete events
    WHERE e.is_late_arrival = TRUE
      AND e.scenario        != 'DELETE'
),

-- ── 3) DELETE check
-- Source sent a delete (afterState = null).
-- Target must: have the row, set dwh_is_deleted_flag = Y,
-- set dwh_latest_dml_type_code = D, and effective_from = delete metadata_time.
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
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        t.dwh_latest_dml_type_code,
        t.dwh_is_deleted_flag,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'FAIL'
             ELSE 'PASS' END                                            AS chk_row_exists,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'N/A'
             WHEN e.exp_effective_from = t.dwh_effective_from_tstamp THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_effective_from,

        'N/A'                                                           AS chk_effective_to,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'N/A'
             WHEN t.dwh_is_deleted_flag = 'Y' THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_deleted_flag,

        CASE WHEN t.CUSTOMER1_NO IS NULL THEN 'N/A'
             WHEN t.dwh_latest_dml_type_code = 'D' THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_dml_type,

        CASE
            WHEN t.CUSTOMER1_NO IS NULL
                THEN 'FAIL - Delete event not reflected in target (record_order '
                     || e.record_order::VARCHAR || ')'
            WHEN t.dwh_is_deleted_flag IS DISTINCT FROM 'Y'
                THEN 'FAIL - dwh_is_deleted_flag not Y (act: '
                     || COALESCE(t.dwh_is_deleted_flag, 'NULL') || ')'
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL - dwh_latest_dml_type_code not D (act: '
                     || COALESCE(t.dwh_latest_dml_type_code, 'NULL') || ')'
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL - delete effective_from mismatch (exp: '
                     || e.exp_effective_from::VARCHAR
                     || ', act: ' || t.dwh_effective_from_tstamp::VARCHAR || ')'
            ELSE 'PASS'
        END                                                             AS final_result,

        'DELETE'                                                        AS check_type

    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.CUSTOMER1_NO      = t.CUSTOMER1_NO
        AND e.RELATIONSHIP_TYPE = t.RELATIONSHIP_TYPE
        AND e.RELATIONSHIP_CODE = t.RELATIONSHIP_CODE
        AND e.CUSTOMER2_NO      = t.CUSTOMER2_NO
        AND e.record_order      = t.record_order
    WHERE e.scenario = 'DELETE'
)

SELECT * FROM insert_update_check
UNION ALL
SELECT * FROM missing_late_check
UNION ALL
SELECT * FROM delete_check

ORDER BY CUSTOMER1_NO, CUSTOMER2_NO, RELATIONSHIP_CODE, RELATIONSHIP_TYPE, record_order, check_type;
