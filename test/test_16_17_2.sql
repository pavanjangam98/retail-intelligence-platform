-- ============================================================================
-- Source vs Target SCD2 Validation — Insert / Update / Missing / Rollback
-- ============================================================================

WITH source_raw AS (

    SELECT
        COALESCE(
            parse_json(record_content):afterState:CUSTOMER1_NO,
            parse_json(record_content):beforeState:CUSTOMER1_NO
        )::NUMBER AS customer1_no,
        COALESCE(
            parse_json(record_content):afterState:CUSTOMER2_NO,
            parse_json(record_content):beforeState:CUSTOMER2_NO
        )::NUMBER AS customer2_no,
        COALESCE(
            parse_json(record_content):afterState:RELATIONSHIP_CODE,
            parse_json(record_content):beforeState:RELATIONSHIP_CODE
        )::VARCHAR AS relationship_code,
        COALESCE(
            parse_json(record_content):afterState:RELATIONSHIP_TYPE,
            parse_json(record_content):beforeState:RELATIONSHIP_TYPE
        )::VARCHAR AS relationship_type,
        parse_json(record_content):metadata:time::TIMESTAMP_NTZ AS metadata_time
    FROM landing__syst.bis.bst_cust_reln          -- <<< source table
    WHERE parse_json(record_content):afterState:CUSTOMER1_NO IS NOT NULL
       OR parse_json(record_content):beforeState:CUSTOMER1_NO IS NOT NULL

),

source_dedup AS (
    SELECT DISTINCT
        customer1_no, customer2_no, relationship_code, relationship_type, metadata_time
    FROM source_raw
),

-- ── expected effective_from / effective_to, computed AS-IF source arrived in correct order
source_expected AS (
    SELECT
        customer1_no, customer2_no, relationship_code, relationship_type,
        metadata_time                                                  AS exp_effective_from,

        TIMESTAMPADD(
            MICROSECOND, -1,
            COALESCE(
                LEAD(metadata_time) OVER (
                    PARTITION BY customer1_no, customer2_no, relationship_code, relationship_type
                    ORDER BY metadata_time ASC
                ),
                '9999-12-31T00:00:00.000001'::TIMESTAMP_NTZ
            )
        )                                                               AS exp_effective_to,

        ROW_NUMBER() OVER (
            PARTITION BY customer1_no, customer2_no, relationship_code, relationship_type
            ORDER BY metadata_time ASC
        )                                                               AS record_order,

        -- flag late arrivals: a record whose metadata_time is earlier than a record
        -- that was already loaded into target before this one arrived (proxy: any
        -- record_order > 1 whose metadata_time is NOT the max seen so far)
        CASE
            WHEN metadata_time < MAX(metadata_time) OVER (
                     PARTITION BY customer1_no, customer2_no, relationship_code, relationship_type
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 )
            THEN TRUE
            ELSE FALSE
        END                                                             AS is_late_arrival,

        CASE
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY customer1_no, customer2_no, relationship_code, relationship_type
                     ORDER BY metadata_time ASC
                 ) = 1
            THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                             AS scenario

    FROM source_dedup
),

target_data AS (
    SELECT
        customer1_no, customer2_no, relationship_code, relationship_type,
        dwh_effective_from_tstamp,
        dwh_effective_to_tstamp,
        dwh_latest_dml_type_code,
        dwh_is_deleted_flag,
        ROW_NUMBER() OVER (
            PARTITION BY customer1_no, customer2_no, relationship_code, relationship_type
            ORDER BY dwh_effective_from_tstamp ASC
        )                                                               AS record_order
    FROM cust__raw__dev.bis.bst_cust_reln          -- <<< target table
),

row_counts AS (
    SELECT
        s.customer1_no, s.customer2_no, s.relationship_code, s.relationship_type,
        COUNT(DISTINCT s.record_order)                                 AS src_version_count,
        COUNT(DISTINCT t.record_order)                                 AS tgt_version_count
    FROM source_expected s
    LEFT JOIN target_data t
        ON  t.customer1_no       = s.customer1_no
        AND t.customer2_no       = s.customer2_no
        AND t.relationship_code  = s.relationship_code
        AND t.relationship_type  = s.relationship_type
    GROUP BY s.customer1_no, s.customer2_no, s.relationship_code, s.relationship_type
),

-- ── 1) INSERT / UPDATE check (existing logic)
insert_update_check AS (
    SELECT
        e.customer1_no, e.customer2_no, e.relationship_code, e.relationship_type,
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        t.dwh_latest_dml_type_code,
        t.dwh_is_deleted_flag,
        rc.src_version_count,
        rc.tgt_version_count,

        CASE
            WHEN t.customer1_no IS NULL
                THEN 'FAIL - Row missing in target for record_order ' || e.record_order::VARCHAR
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL - effective_from mismatch (exp: ' || e.exp_effective_from::VARCHAR
                     || ', act: ' || t.dwh_effective_from_tstamp::VARCHAR || ')'
            WHEN e.exp_effective_to <> t.dwh_effective_to_tstamp
                THEN 'FAIL - effective_to mismatch (exp: ' || e.exp_effective_to::VARCHAR
                     || ', act: ' || t.dwh_effective_to_tstamp::VARCHAR || ')'
            WHEN rc.src_version_count <> rc.tgt_version_count
                THEN 'FAIL - version count mismatch (src: ' || rc.src_version_count::VARCHAR
                     || ', tgt: ' || rc.tgt_version_count::VARCHAR || ')'
            ELSE 'PASS'
        END                                                              AS final_result,

        'INSERT_UPDATE'                                                 AS check_type

    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.customer1_no      = t.customer1_no
        AND e.customer2_no      = t.customer2_no
        AND e.relationship_code = t.relationship_code
        AND e.relationship_type = t.relationship_type
        AND e.record_order      = t.record_order
    LEFT JOIN row_counts rc
        ON  rc.customer1_no      = e.customer1_no
        AND rc.customer2_no      = e.customer2_no
        AND rc.relationship_code = e.relationship_code
        AND rc.relationship_type = e.relationship_type
),

-- ── 2) MISSING LATE RECORDS — source has a version target never received at all
missing_check AS (
    SELECT
        e.customer1_no, e.customer2_no, e.relationship_code, e.relationship_type,
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        NULL                                                            AS act_effective_from,
        NULL                                                            AS act_effective_to,
        NULL                                                            AS dwh_latest_dml_type_code,
        NULL                                                            AS dwh_is_deleted_flag,
        rc.src_version_count,
        rc.tgt_version_count,
        'FAIL - Missing late record (source metadata_time '
            || e.exp_effective_from::VARCHAR || ' never landed in target)'  AS final_result,
        'MISSING_LATE_RECORD'                                           AS check_type
    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.customer1_no      = t.customer1_no
        AND e.customer2_no      = t.customer2_no
        AND e.relationship_code = t.relationship_code
        AND e.relationship_type = t.relationship_type
        AND e.exp_effective_from = t.dwh_effective_from_tstamp
    LEFT JOIN row_counts rc
        ON  rc.customer1_no      = e.customer1_no
        AND rc.customer2_no      = e.customer2_no
        AND rc.relationship_code = e.relationship_code
        AND rc.relationship_type = e.relationship_type
    WHERE t.customer1_no IS NULL
),

-- ── 3) ROLLBACK — late-arriving source record (existence check only, per your scope)
rollback_check AS (
    SELECT
        e.customer1_no, e.customer2_no, e.relationship_code, e.relationship_type,
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        t.dwh_latest_dml_type_code,
        t.dwh_is_deleted_flag,
        rc.src_version_count,
        rc.tgt_version_count,
        CASE
            WHEN t.customer1_no IS NULL
                THEN 'FAIL - Rollback record not found in target (late arrival '
                     || e.exp_effective_from::VARCHAR || ')'
            ELSE 'PASS'
        END                                                              AS final_result,
        'ROLLBACK'                                                      AS check_type
    FROM source_expected e
    LEFT JOIN target_data t
        ON  e.customer1_no      = t.customer1_no
        AND e.customer2_no      = t.customer2_no
        AND e.relationship_code = t.relationship_code
        AND e.relationship_type = t.relationship_type
        AND e.exp_effective_from = t.dwh_effective_from_tstamp
    LEFT JOIN row_counts rc
        ON  rc.customer1_no      = e.customer1_no
        AND rc.customer2_no      = e.customer2_no
        AND rc.relationship_code = e.relationship_code
        AND rc.relationship_type = e.relationship_type
    WHERE e.is_late_arrival = TRUE
)

SELECT * FROM insert_update_check
UNION ALL
SELECT * FROM missing_check
UNION ALL
SELECT * FROM rollback_check

ORDER BY customer1_no, customer2_no, relationship_code, relationship_type, record_order, check_type;
