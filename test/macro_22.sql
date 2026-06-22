{% macro test_scd2_cdc_validation(
    source_relation,
    target_relation,
    key_columns,
    source_json_column,
    source_key_paths,
    source_time_path,
    target_from_column,
    target_to_column,
    target_deleted_flag_column,
    target_dml_type_column,
    afterState="afterState",
    beforeState="beforeState",
    look_back=25,
    lag_minutes=60,
    raise_error=False
) %}

-- ============================================================
-- Macro: test_scd2_cdc_validation
-- Validates SCD Type-2 CDC pipeline from landing to target.
-- Supports: INSERT / UPDATE / DELETE / LATE ARRIVAL scenarios.
--
-- Parameters:
--   source_relation            : landing table (e.g. landing__dev.bis.BST_CUST_RELN)
--   target_relation            : target SCD2 table (e.g. cust__raw__dev.bis.bst_cust_reln)
--   key_columns                : list of business key column names
--                                e.g. ['CUSTOMER1_NO','RELATIONSHIP_TYPE','RELATIONSHIP_CODE','CUSTOMER2_NO']
--   source_json_column         : the variant/JSON column in source (e.g. 'RECORD_CONTENT')
--   source_key_paths           : JSON paths for each key inside afterState/beforeState
--                                e.g. ['CUSTOMER1_NO','RELATIONSHIP_TYPE','RELATIONSHIP_CODE','CUSTOMER2_NO']
--   source_time_path           : JSON path to the event timestamp (e.g. 'metadata:time')
--   target_from_column         : effective_from column in target (e.g. 'dwh_effective_from_tstamp')
--   target_to_column           : effective_to column in target   (e.g. 'dwh_effective_to_tstamp')
--   target_deleted_flag_column : deleted flag column in target   (e.g. 'dwh_is_deleted_flag')
--   target_dml_type_column     : DML type column in target       (e.g. 'dwh_latest_dml_type_code')
--   afterState                 : JSON key for after-image  (default: 'afterState')
--   beforeState                : JSON key for before-image (default: 'beforeState')
--   look_back                  : days to look back (default: 25)
--   lag_minutes                : minutes of lag to exclude recent unprocessed data (default: 60)
--   raise_error                : raise compiler error on failure (default: False)
-- ============================================================

{{ log("=== SCD2 CDC Validation Macro Started ===", info=True) }}
{{ log("Source Relation            : " ~ source_relation,            info=True) }}
{{ log("Target Relation            : " ~ target_relation,            info=True) }}
{{ log("Key Columns                : " ~ key_columns,                info=True) }}
{{ log("Source JSON Column         : " ~ source_json_column,         info=True) }}
{{ log("Source Key Paths           : " ~ source_key_paths,           info=True) }}
{{ log("Source Time Path           : " ~ source_time_path,           info=True) }}
{{ log("Target From Column         : " ~ target_from_column,         info=True) }}
{{ log("Target To Column           : " ~ target_to_column,           info=True) }}
{{ log("Target Deleted Flag Column : " ~ target_deleted_flag_column, info=True) }}
{{ log("Target DML Type Column     : " ~ target_dml_type_column,     info=True) }}
{{ log("After State Key            : " ~ afterState,                 info=True) }}
{{ log("Before State Key           : " ~ beforeState,                info=True) }}
{{ log("Look Back (days)           : " ~ look_back,                  info=True) }}
{{ log("Lag Minutes                : " ~ lag_minutes,                info=True) }}

{# Validate that key_columns and source_key_paths have equal length #}
{% if key_columns | length != source_key_paths | length %}
    {{ exceptions.raise_compiler_error(
        "key_columns and source_key_paths must be the same length. Got "
        ~ key_columns | length ~ " key_columns and "
        ~ source_key_paths | length ~ " source_key_paths."
    ) }}
{% endif %}

{# Capture current timestamp for consistent time window across all CTEs #}
{% set current_ts = None %}
{% if execute %}
    {% set current_ts_query %}
        SELECT CURRENT_TIMESTAMP AS current_ts
    {% endset %}
    {% set current_ts_result = run_query(current_ts_query) %}
    {% set current_ts = current_ts_result.columns[0].values()[0] %}
    {{ log("Current Timestamp : " ~ current_ts, info=True) }}
{% endif %}

{# Helper: build partition key list prefixed with an alias #}
{% macro partition_cols(alias) %}
    {% for col in key_columns %}{{ alias }}.{{ col }}{% if not loop.last %}, {% endif %}{% endfor %}
{% endmacro %}

{# Helper: build JOIN ON clause between two aliases #}
{% macro join_on(alias_a, alias_b) %}
    {% for col in key_columns %}
        {{ alias_a }}.{{ col }} = {{ alias_b }}.{{ col }}{% if not loop.last %} AND {% endif %}
    {% endfor %}
{% endmacro %}

{% set generated_sql %}

WITH source_raw AS (
    SELECT DISTINCT
        {# ── Key columns: prefer afterState, fallback to beforeState ── #}
        {% for col, path in zip(key_columns, source_key_paths) %}
        IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )                                                               AS {{ col }},
        {% endfor %}

        {# ── Event timestamp ── #}
        {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ AS metadata_time,

        {# ── Delete event detection:                              ── #}
        {# ──   afterState = NULL_VALUE + beforeState = OBJECT    ── #}
        CASE
            WHEN TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE'
             AND TYPEOF({{ source_json_column }}:{{ beforeState }}) = 'OBJECT'
            THEN TRUE
            ELSE FALSE
        END                                                             AS is_delete_event

    FROM {{ source_relation }}

    {# Time window: exclude recent lag + limit to look_back days #}
    WHERE {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ
              <= DATEADD(MINUTE, -{{ lag_minutes }}, '{{ current_ts }}'::TIMESTAMP_TZ)
      AND {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ
              >= DATEADD(DAY,    -{{ look_back }},   '{{ current_ts }}'::TIMESTAMP_TZ)
),

source_dedup AS (
    SELECT DISTINCT
        {% for col in key_columns %}{{ col }}, {% endfor %}
        metadata_time,
        is_delete_event
    FROM source_raw
),

source_expected AS (
    SELECT
        {% for col in key_columns %}{{ col }}, {% endfor %}

        metadata_time                                                   AS exp_effective_from,

        {# Expected effective_to = next event time - 1µs, or far-future sentinel #}
        TIMESTAMPADD(
            MICROSECOND, -1,
            COALESCE(
                LEAD(metadata_time) OVER (
                    PARTITION BY {{ key_columns | join(', ') }}
                    ORDER BY metadata_time ASC
                ),
                '9999-12-31T00:00:00.000001'::TIMESTAMP_NTZ
            )
        )                                                               AS exp_effective_to,

        {# Source row number — includes DELETE rows #}
        ROW_NUMBER() OVER (
            PARTITION BY {{ key_columns | join(', ') }}
            ORDER BY metadata_time ASC
        )                                                               AS record_order,

        is_delete_event,

        {# Late arrival: event arrived after a later event was already processed #}
        CASE
            WHEN metadata_time < MAX(metadata_time) OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 )
            THEN TRUE
            ELSE FALSE
        END                                                             AS is_late_arrival,

        {# Scenario: DELETE / INSERT (first non-delete) / UPDATE #}
        CASE
            WHEN is_delete_event = TRUE THEN 'DELETE'
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                 ) = 1              THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                             AS scenario,

        {# Phantom INSERT offset:                                          #}
        {# If first source event is DELETE, target has an INSERT row that  #}
        {# predates the landing window → offset target_record_order by +1  #}
        CASE
            WHEN FIRST_VALUE(is_delete_event) OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
                 ) = TRUE
            THEN 1
            ELSE 0
        END                                                             AS first_event_is_delete_offset,

        {# target_record_order:                                             #}
        {# Counts only non-DELETE source rows (+ phantom offset).           #}
        {# Aligns source numbering with target physical rows because DELETE  #}
        {# updates an existing target row — it does NOT add a new row.      #}
        SUM(CASE WHEN is_delete_event = FALSE THEN 1 ELSE 0 END) OVER (
            PARTITION BY {{ key_columns | join(', ') }}
            ORDER BY metadata_time ASC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
        +
        CASE
            WHEN FIRST_VALUE(is_delete_event) OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
                 ) = TRUE
            THEN 1
            ELSE 0
        END                                                             AS target_record_order

    FROM source_dedup
),

{# Target physical rows with aligned row numbering #}
target_data AS (
    SELECT
        {% for col in key_columns %}{{ col }}, {% endfor %}
        {{ target_from_column }}                                        AS dwh_effective_from_tstamp,
        {{ target_to_column }}                                          AS dwh_effective_to_tstamp,
        {{ target_deleted_flag_column }}                                AS dwh_is_deleted_flag,
        {{ target_dml_type_column }}                                    AS dwh_latest_dml_type_code,
        ROW_NUMBER() OVER (
            PARTITION BY {{ key_columns | join(', ') }}
            ORDER BY {{ target_from_column }} ASC
        )                                                               AS record_order
    FROM {{ target_relation }}
    WHERE {{ target_from_column }}
              <= DATEADD(MINUTE, -{{ lag_minutes }}, '{{ current_ts }}'::TIMESTAMP_TZ)
      AND {{ target_from_column }}
              >= DATEADD(DAY,    -{{ look_back }},   '{{ current_ts }}'::TIMESTAMP_TZ)
),

{# Version count per key group — src vs tgt #}
row_counts AS (
    SELECT
        {% for col in key_columns %}s.{{ col }}, {% endfor %}
        COUNT(DISTINCT s.target_record_order)                           AS src_version_count,
        COUNT(DISTINCT t.record_order)                                  AS tgt_version_count
    FROM source_expected s
    LEFT JOIN target_data t
        ON  {% for col in key_columns %}
            s.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
    GROUP BY
        {% for col in key_columns %}s.{{ col }}{% if not loop.last %}, {% endif %}{% endfor %}
),

-- ============================================================
-- CHECK 1: INSERT and UPDATE (including late arrivals)
-- ============================================================
insert_update_check AS (
    SELECT
        {% for col in key_columns %}e.{{ col }}, {% endfor %}
        e.record_order,

        CASE
            WHEN e.is_late_arrival = TRUE THEN e.scenario || '_LATE'
            ELSE e.scenario
        END                                                             AS scenario,

        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        rc.src_version_count,
        rc.tgt_version_count,

        CASE WHEN t.{{ key_columns[0] }} IS NULL THEN 'FAIL' ELSE 'PASS'
        END                                                             AS chk_row_exists,

        CASE WHEN t.{{ key_columns[0] }} IS NULL                             THEN 'N/A'
             WHEN e.exp_effective_from = t.dwh_effective_from_tstamp         THEN 'PASS'
             ELSE 'FAIL'
        END                                                             AS chk_effective_from,

        CASE WHEN t.{{ key_columns[0] }} IS NULL                             THEN 'N/A'
             WHEN e.exp_effective_to   = t.dwh_effective_to_tstamp           THEN 'PASS'
             ELSE 'FAIL'
        END                                                             AS chk_effective_to,

        CASE WHEN rc.src_version_count = rc.tgt_version_count THEN 'PASS' ELSE 'FAIL'
        END                                                             AS chk_version_count,

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
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
        END                                                             AS final_result

    FROM source_expected e
    LEFT JOIN target_data t
        ON  {% for col in key_columns %}
            e.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND e.target_record_order = t.record_order
    LEFT JOIN row_counts rc
        ON  {% for col in key_columns %}
            rc.{{ col }} = e.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
    WHERE e.scenario IN ('INSERT', 'UPDATE')
),

-- ============================================================
-- CHECK 2: DELETE scenario
-- ============================================================
delete_check AS (
    SELECT
        {% for col in key_columns %}e.{{ col }}, {% endfor %}
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        rc.src_version_count,
        rc.tgt_version_count,

        CASE WHEN t.{{ key_columns[0] }} IS NULL THEN 'FAIL' ELSE 'PASS'
        END                                                             AS chk_row_exists,

        CASE WHEN t.{{ key_columns[0] }} IS NULL                             THEN 'N/A'
             WHEN e.exp_effective_from = t.dwh_effective_from_tstamp         THEN 'PASS'
             ELSE 'FAIL'
        END                                                             AS chk_effective_from,

        CASE WHEN t.{{ key_columns[0] }} IS NULL                             THEN 'N/A'
             WHEN e.exp_effective_to   = t.dwh_effective_to_tstamp           THEN 'PASS'
             ELSE 'FAIL'
        END                                                             AS chk_effective_to,

        CASE WHEN rc.src_version_count = rc.tgt_version_count THEN 'PASS' ELSE 'FAIL'
        END                                                             AS chk_version_count,

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Deleted row missing in target for record_order ' || e.record_order::VARCHAR
            WHEN t.dwh_is_deleted_flag IS DISTINCT FROM 'Y'
                THEN 'FAIL - dwh_is_deleted_flag is not Y (actual: ' || COALESCE(t.dwh_is_deleted_flag, 'NULL') || ')'
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL - dwh_latest_dml_type_code is not D (actual: ' || COALESCE(t.dwh_latest_dml_type_code, 'NULL') || ')'
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
        END                                                             AS final_result

    FROM source_expected e
    LEFT JOIN target_data t
        ON  {% for col in key_columns %}
            e.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND e.target_record_order = t.record_order
    LEFT JOIN row_counts rc
        ON  {% for col in key_columns %}
            rc.{{ col }} = e.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
    WHERE e.scenario = 'DELETE'
),

-- ============================================================
-- CHECK 3: Late arrival — prior row back-dating
-- ============================================================
missing_late_check AS (
    SELECT
        {% for col in key_columns %}e.{{ col }}, {% endfor %}
        e.record_order,
        'LATE_PRIOR_ROW_BACKDATE'                                       AS scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        prev_t.dwh_effective_from_tstamp                                AS act_effective_from,
        prev_t.dwh_effective_to_tstamp                                  AS act_effective_to,
        rc.src_version_count,
        rc.tgt_version_count,

        CASE WHEN prev_t.{{ key_columns[0] }} IS NULL THEN 'FAIL' ELSE 'PASS'
        END                                                             AS chk_row_exists,

        'N/A'                                                           AS chk_effective_from,

        CASE WHEN prev_t.{{ key_columns[0] }} IS NULL THEN 'N/A'
             WHEN prev_t.dwh_effective_to_tstamp =
                  TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)  THEN 'PASS'
             ELSE 'FAIL'
        END                                                             AS chk_effective_to,

        CASE WHEN rc.src_version_count = rc.tgt_version_count THEN 'PASS' ELSE 'FAIL'
        END                                                             AS chk_version_count,

        CASE
            WHEN prev_t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Prior target row not found for record_order '
                     || (e.target_record_order - 1)::VARCHAR
            WHEN prev_t.dwh_effective_to_tstamp IS DISTINCT FROM
                 TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)
                THEN 'FAIL - Prior row not back-dated (exp: '
                     || TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)::VARCHAR
                     || ', act: ' || prev_t.dwh_effective_to_tstamp::VARCHAR || ')'
            WHEN rc.src_version_count <> rc.tgt_version_count
                THEN 'FAIL - version count mismatch (src: ' || rc.src_version_count::VARCHAR
                     || ', tgt: ' || rc.tgt_version_count::VARCHAR || ')'
            ELSE 'PASS'
        END                                                             AS final_result

    FROM source_expected e
    LEFT JOIN target_data prev_t
        ON  {% for col in key_columns %}
            e.{{ col }} = prev_t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND (e.target_record_order - 1) = prev_t.record_order
    LEFT JOIN row_counts rc
        ON  {% for col in key_columns %}
            rc.{{ col }} = e.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
    WHERE e.is_late_arrival = TRUE
      AND e.scenario <> 'DELETE'
)

SELECT * FROM insert_update_check
UNION ALL
SELECT * FROM delete_check
UNION ALL
SELECT * FROM missing_late_check

ORDER BY
    {% for col in key_columns %}{{ col }}, {% endfor %}
    record_order, scenario

{% endset %}

{{ log("=== Generated SCD2 CDC Validation SQL ===", info=True) }}
{{ log(generated_sql, info=True) }}
{{ log("=== End of Generated SQL ===", info=True) }}

{% if execute %}
    {% set results = run_query(generated_sql) %}
    {% set fail_rows = results.rows | selectattr("final_result", "ne", "PASS") | list %}
    {% set fail_count = fail_rows | length %}

    {{ log("[SCD2 CDC Check] Total rows checked : " ~ results.rows | length, info=True) }}
    {{ log("[SCD2 CDC Check] Failing rows found : " ~ fail_count,           info=True) }}

    {% if fail_count > 0 %}
        {{ log("Connect with data team for refresh", info=True) }}
        {% if raise_error %}
            {{ exceptions.raise_compiler_error(
                "SCD2 CDC validation FAILED for " ~ target_relation ~ " — "
                ~ fail_count ~ " failing row(s) found in the last "
                ~ look_back ~ " day(s). Check dbt.log for details."
            ) }}
        {% else %}
            {{ log("Warning: SCD2 CDC validation failed but continuing (raise_error=False).", info=True) }}
        {% endif %}
    {% else %}
        {{ log("SCD2 CDC validation PASSED for " ~ target_relation
               ~ " (last " ~ look_back ~ " day(s))", info=True) }}
    {% endif %}
{% endif %}

{{ return(generated_sql) }}

{% endmacro %}

-- ============================================================
-- USAGE EXAMPLE
-- ============================================================
-- {{ test_scd2_cdc_validation(
--     source_relation            = ref('BST_CUST_RELN_FULL_VIEW'),
--     target_relation            = ref('bst_cust_reln'),
--     key_columns                = [
--                                     'CUSTOMER1_NO',
--                                     'RELATIONSHIP_TYPE',
--                                     'RELATIONSHIP_CODE',
--                                     'CUSTOMER2_NO'
--                                  ],
--     source_json_column         = 'RECORD_CONTENT',
--     source_key_paths           = [
--                                     'CUSTOMER1_NO',
--                                     'RELATIONSHIP_TYPE',
--                                     'RELATIONSHIP_CODE',
--                                     'CUSTOMER2_NO'
--                                  ],
--     source_time_path           = 'metadata:time',
--     target_from_column         = 'dwh_effective_from_tstamp',
--     target_to_column           = 'dwh_effective_to_tstamp',
--     target_deleted_flag_column = 'dwh_is_deleted_flag',
--     target_dml_type_column     = 'dwh_latest_dml_type_code',
--     afterState                 = 'afterState',
--     beforeState                = 'beforeState',
--     look_back                  = 25,
--     lag_minutes                = 60,
--     raise_error                = False
-- ) }}
