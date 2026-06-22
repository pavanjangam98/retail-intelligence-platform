{% macro test_scd2_cdc_validation(
    source_relation,
    target_relation,
    key_columns,
    source_json_column,
    source_key_paths,
    source_key_types,
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

{# =================================================================
   Macro : test_scd2_cdc_validation
   Validates SCD Type-2 CDC pipeline from landing to target.
   Supports : INSERT / UPDATE / DELETE / LATE ARRIVAL scenarios.

   Parameters
   ----------
   source_relation            : landing table
                                e.g. ref('BST_CUST_RELN_FULL_VIEW')
   target_relation            : target SCD2 table
                                e.g. ref('bst_cust_reln')
   key_columns                : business key column names (list)
                                e.g. ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                      'RELATIONSHIP_CODE','CUSTOMER2_NO']
   source_json_column         : variant/JSON column in source
                                e.g. 'RECORD_CONTENT'
   source_key_paths           : JSON sub-paths for each key inside
                                afterState / beforeState (list, same
                                order as key_columns)
                                e.g. ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                      'RELATIONSHIP_CODE','CUSTOMER2_NO']
   source_key_types           : cast type for each key column (list,
                                same order as key_columns).
                                Use 'NUMBER', 'VARCHAR', 'TRIM_VARCHAR'
                                (TRIM_VARCHAR applies double-trim + quote
                                removal as in original SQL)
                                e.g. ['NUMBER','TRIM_VARCHAR',
                                      'TRIM_VARCHAR','NUMBER']
   source_time_path           : JSON path to event timestamp
                                e.g. 'metadata:time'
   target_from_column         : effective_from column in target
                                e.g. 'dwh_effective_from_tstamp'
   target_to_column           : effective_to column in target
                                e.g. 'dwh_effective_to_tstamp'
   target_deleted_flag_column : deleted flag column in target
                                e.g. 'dwh_is_deleted_flag'
   target_dml_type_column     : DML type column in target
                                e.g. 'dwh_latest_dml_type_code'
   afterState                 : JSON key for after-image
                                (default: 'afterState')
   beforeState                : JSON key for before-image
                                (default: 'beforeState')
   look_back                  : days to look back (default: 25)
   lag_minutes                : minutes of lag to exclude unprocessed
                                recent data (default: 60)
   raise_error                : raise compiler error on failure
                                (default: False)
================================================================= #}

{{ log("=== SCD2 CDC Validation Macro Started ===",               info=True) }}
{{ log("Source Relation            : " ~ source_relation,         info=True) }}
{{ log("Target Relation            : " ~ target_relation,         info=True) }}
{{ log("Key Columns                : " ~ key_columns,             info=True) }}
{{ log("Source JSON Column         : " ~ source_json_column,      info=True) }}
{{ log("Source Key Paths           : " ~ source_key_paths,        info=True) }}
{{ log("Source Key Types           : " ~ source_key_types,        info=True) }}
{{ log("Source Time Path           : " ~ source_time_path,        info=True) }}
{{ log("Target From Column         : " ~ target_from_column,      info=True) }}
{{ log("Target To Column           : " ~ target_to_column,        info=True) }}
{{ log("Target Deleted Flag Column : " ~ target_deleted_flag_column, info=True) }}
{{ log("Target DML Type Column     : " ~ target_dml_type_column,  info=True) }}
{{ log("After State Key            : " ~ afterState,              info=True) }}
{{ log("Before State Key           : " ~ beforeState,             info=True) }}
{{ log("Look Back (days)           : " ~ look_back,               info=True) }}
{{ log("Lag Minutes                : " ~ lag_minutes,             info=True) }}

{# ── Validate list lengths match ── #}
{% if key_columns | length != source_key_paths | length %}
    {{ exceptions.raise_compiler_error(
        "key_columns and source_key_paths must be the same length. Got "
        ~ key_columns | length ~ " key_columns and "
        ~ source_key_paths | length ~ " source_key_paths."
    ) }}
{% endif %}

{% if key_columns | length != source_key_types | length %}
    {{ exceptions.raise_compiler_error(
        "key_columns and source_key_types must be the same length. Got "
        ~ key_columns | length ~ " key_columns and "
        ~ source_key_types | length ~ " source_key_types."
    ) }}
{% endif %}

{# ── Capture current timestamp once for consistent time windows ── #}
{% set current_ts = None %}
{% if execute %}
    {% set current_ts_query %}
        SELECT CURRENT_TIMESTAMP AS current_ts
    {% endset %}
    {% set current_ts_result = run_query(current_ts_query) %}
    {% set current_ts = current_ts_result.columns[0].values()[0] %}
    {{ log("Current Timestamp : " ~ current_ts, info=True) }}
{% endif %}

{# ================================================================
   Helper macro : render one key column extraction from JSON.

   source_key_types controls casting / trimming:
     NUMBER        → ::NUMBER
     VARCHAR       → TRIM(...::VARCHAR, '"')           (remove quotes)
     TRIM_VARCHAR  → TRIM(TRIM(...::VARCHAR, '"'))     (double-trim)
================================================================ #}
{% macro extract_key(col, path, key_type) %}
    {% if key_type == 'NUMBER' %}
        IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::NUMBER
    {% elif key_type == 'VARCHAR' %}
        TRIM(IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::VARCHAR, '"')
    {% elif key_type == 'TRIM_VARCHAR' %}
        TRIM(TRIM(IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::VARCHAR, '"'))
    {% else %}
        IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::VARCHAR
    {% endif %}
{% endmacro %}

{# ================================================================
   Helper macro : render target SELECT for one key column.
   TRIM_VARCHAR keys need TRIM() in target too (matches source_raw).
================================================================ #}
{% macro target_key(col, key_type) %}
    {% if key_type == 'TRIM_VARCHAR' %}
        TRIM({{ col }}) AS {{ col }}
    {% else %}
        {{ col }}
    {% endif %}
{% endmacro %}

{# ================================================================
   Helper macro : PARTITION BY clause for target ROW_NUMBER.
   TRIM_VARCHAR keys need explicit TRIM() because window functions
   cannot reference aliases defined in the same SELECT list.
================================================================ #}
{% macro target_partition_key(col, key_type) %}
    {% if key_type == 'TRIM_VARCHAR' %}
        TRIM({{ col }})
    {% else %}
        {{ col }}
    {% endif %}
{% endmacro %}

{# ── Build the full SQL string ── #}
{% set generated_sql %}

WITH source_raw AS (
    SELECT DISTINCT
        {# Key columns — extract from JSON with correct cast / trim #}
        {% for i in range(key_columns | length) %}
        {{ extract_key(
               key_columns[i],
               source_key_paths[i],
               source_key_types[i]
           ) }}                                                          AS {{ key_columns[i] }},
        {% endfor %}

        {# Event timestamp #}
        {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ  AS metadata_time,

        {# Delete event detection:
           afterState = NULL_VALUE  AND  beforeState = OBJECT  →  TRUE #}
        CASE
            WHEN TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE'
             AND TYPEOF({{ source_json_column }}:{{ beforeState }}) = 'OBJECT'
            THEN TRUE
            ELSE FALSE
        END                                                              AS is_delete_event

    FROM {{ source_relation }}
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

        metadata_time                                                    AS exp_effective_from,

        {# exp_effective_to = next event time − 1 µs, or far-future sentinel #}
        TIMESTAMPADD(
            MICROSECOND, -1,
            COALESCE(
                LEAD(metadata_time) OVER (
                    PARTITION BY {{ key_columns | join(', ') }}
                    ORDER BY metadata_time ASC
                ),
                '9999-12-31T00:00:00.000001'::TIMESTAMP_NTZ
            )
        )                                                                AS exp_effective_to,

        ROW_NUMBER() OVER (
            PARTITION BY {{ key_columns | join(', ') }}
            ORDER BY metadata_time ASC
        )                                                                AS record_order,

        is_delete_event,

        {# Late arrival: event arrived after a later event already processed #}
        CASE
            WHEN metadata_time < MAX(metadata_time) OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 )
            THEN TRUE
            ELSE FALSE
        END                                                              AS is_late_arrival,

        {# Scenario: DELETE / INSERT (first row) / UPDATE #}
        CASE
            WHEN is_delete_event = TRUE THEN 'DELETE'
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                 ) = 1              THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                              AS scenario

    FROM source_dedup
),

target_data AS (
    SELECT
        {# Apply TRIM to TRIM_VARCHAR keys; pass others through as-is #}
        {% for i in range(key_columns | length) %}
        {{ target_key(key_columns[i], source_key_types[i]) }},
        {% endfor %}

        {{ target_from_column }}                                         AS dwh_effective_from_tstamp,
        {{ target_to_column }}                                           AS dwh_effective_to_tstamp,
        {{ target_dml_type_column }}                                     AS dwh_latest_dml_type_code,
        {{ target_deleted_flag_column }}                                 AS dwh_is_deleted_flag,

        ROW_NUMBER() OVER (
            PARTITION BY
                {# TRIM_VARCHAR keys need explicit TRIM() here —
                   aliases are not yet resolved in window functions #}
                {% for i in range(key_columns | length) %}
                {{ target_partition_key(key_columns[i], source_key_types[i]) }}{% if not loop.last %}, {% endif %}
                {% endfor %}
            ORDER BY {{ target_from_column }} ASC
        )                                                                AS record_order

    FROM {{ target_relation }}
),

-- ============================================================
-- CHECK 1 : INSERT and UPDATE (including late arrivals)
-- Joins source_expected to target_data on the full key +
-- record_order. Verifies effective_from and effective_to match.
-- Late arrival rows are labelled <SCENARIO>_LATE in scenario col.
-- ============================================================
insert_update_check AS (
    SELECT
        {% for col in key_columns %}e.{{ col }}, {% endfor %}
        e.record_order,

        CASE
            WHEN e.is_late_arrival = TRUE THEN e.scenario || '_LATE'
            ELSE e.scenario
        END                                                              AS scenario,

        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp,
        t.dwh_effective_to_tstamp,

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL'   -- row missing in target
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL'   -- effective_from mismatch
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp
                THEN 'FAIL'   -- effective_to mismatch
            ELSE 'PASS'
        END                                                              AS row_result

    FROM source_expected e
    LEFT JOIN target_data t
        ON  {% for col in key_columns %}
            e.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND e.record_order = t.record_order
    WHERE e.scenario IN ('INSERT', 'UPDATE')
),

-- ============================================================
-- CHECK 2 : DELETE scenario
-- Verifies the target row flagged D/Y has correct timestamps.
-- DELETE in source updates an existing target row (same
-- record_order) — it does NOT insert a new row.
-- ============================================================
delete_check AS (
    SELECT
        {% for col in key_columns %}e.{{ col }}, {% endfor %}
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp,
        t.dwh_effective_to_tstamp,

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL'   -- row missing in target
            WHEN t.dwh_is_deleted_flag IS DISTINCT FROM 'Y'
                THEN 'FAIL'   -- deleted flag not set to Y
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL'   -- DML type not set to D
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL'   -- effective_from mismatch
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp
                THEN 'FAIL'   -- effective_to mismatch
            ELSE 'PASS'
        END                                                              AS row_result

    FROM source_expected e
    LEFT JOIN target_data t
        ON  {% for col in key_columns %}
            e.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND e.record_order = t.record_order
    WHERE e.scenario = 'DELETE'
),

-- ============================================================
-- CHECK 3 : Late arrival — prior row back-dating
-- When a late event lands between two existing target rows,
-- the PRIOR target row's effective_to must be back-dated to
-- (late_arrival_effective_from − 1 µs).
-- Without this check, prior row stays at 9999-12-31 causing
-- an overlap in SCD Type-2 history.
-- Joins on (record_order − 1) to fetch the prior target row.
-- ============================================================
missing_late_check AS (
    SELECT
        {% for col in key_columns %}e.{{ col }}, {% endfor %}
        e.record_order,
        'LATE_PRIOR_ROW_BACKDATE'                                        AS scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        prev_t.dwh_effective_from_tstamp,
        prev_t.dwh_effective_to_tstamp,

        CASE
            WHEN prev_t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL'   -- prior target row does not exist
            WHEN prev_t.dwh_effective_to_tstamp IS DISTINCT FROM
                 TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)
                THEN 'FAIL'   -- prior row not back-dated correctly
            ELSE 'PASS'
        END                                                              AS row_result

    FROM source_expected e
    LEFT JOIN target_data prev_t
        ON  {% for col in key_columns %}
            e.{{ col }} = prev_t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND prev_t.record_order = e.record_order - 1
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
    record_order,
    scenario

{% endset %}

{{ log("=== Generated SCD2 CDC Validation SQL ===", info=True) }}
{{ log(generated_sql, info=True) }}
{{ log("=== End of Generated SQL ===",              info=True) }}

{% if execute %}
    {% set results   = run_query(generated_sql) %}
    {% set fail_count = results.rows
                        | selectattr("row_result", "ne", "PASS")
                        | list | length %}

    {{ log("[SCD2 CDC Check] Total rows checked : " ~ results.rows | length, info=True) }}
    {{ log("[SCD2 CDC Check] Failing rows found : " ~ fail_count,            info=True) }}

    {% if fail_count > 0 %}
        {{ log("Connect with data team for refresh", info=True) }}
        {% if raise_error %}
            {{ exceptions.raise_compiler_error(
                "SCD2 CDC validation FAILED for " ~ target_relation ~ " — "
                ~ fail_count ~ " failing row(s) found. "
                ~ "Check dbt.log for details."
            ) }}
        {% else %}
            {{ log("Warning: SCD2 CDC validation failed but continuing (raise_error=False).", info=True) }}
        {% endif %}
    {% else %}
        {{ log("SCD2 CDC validation PASSED for " ~ target_relation, info=True) }}
    {% endif %}
{% endif %}

{{ return(generated_sql) }}

{% endmacro %}


{# =================================================================
   USAGE EXAMPLE
   Save this file as:
     macros/test_scd2_cdc_validation.sql

   Call from a dbt test or analysis file:
   ================================================================= #}

{#
{{ test_scd2_cdc_validation(
    source_relation            = ref('BST_CUST_RELN_FULL_VIEW'),
    target_relation            = ref('bst_cust_reln'),

    key_columns                = [
                                    'CUSTOMER1_NO',
                                    'RELATIONSHIP_TYPE',
                                    'RELATIONSHIP_CODE',
                                    'CUSTOMER2_NO'
                                 ],

    source_json_column         = 'RECORD_CONTENT',

    source_key_paths           = [
                                    'CUSTOMER1_NO',
                                    'RELATIONSHIP_TYPE',
                                    'RELATIONSHIP_CODE',
                                    'CUSTOMER2_NO'
                                 ],

    source_key_types           = [
                                    'NUMBER',         -- CUSTOMER1_NO   → ::NUMBER
                                    'TRIM_VARCHAR',   -- RELATIONSHIP_TYPE → TRIM(TRIM(...)::VARCHAR,'"')
                                    'TRIM_VARCHAR',   -- RELATIONSHIP_CODE → TRIM(TRIM(...)::VARCHAR,'"')
                                    'NUMBER'          -- CUSTOMER2_NO   → ::NUMBER
                                 ],

    source_time_path           = 'metadata:time',
    target_from_column         = 'dwh_effective_from_tstamp',
    target_to_column           = 'dwh_effective_to_tstamp',
    target_deleted_flag_column = 'dwh_is_deleted_flag',
    target_dml_type_column     = 'dwh_latest_dml_type_code',
    afterState                 = 'afterState',
    beforeState                = 'beforeState',
    look_back                  = 25,
    lag_minutes                = 60,
    raise_error                = False
) }}
#}
