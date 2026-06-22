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
{{ log("Look Back (days)           : " ~ look_back,               info=True) }}
{{ log("Lag Minutes                : " ~ lag_minutes,             info=True) }}

{# Validate list lengths #}
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

{# Capture current timestamp once for consistent time windows #}
{% set current_ts = None %}
{% if execute %}
    {% set current_ts_query %}
        SELECT CURRENT_TIMESTAMP AS current_ts
    {% endset %}
    {% set current_ts_result = run_query(current_ts_query) %}
    {% set current_ts = current_ts_result.columns[0].values()[0] %}
    {{ log("Current Timestamp : " ~ current_ts, info=True) }}
{% endif %}

{% set generated_sql %}

WITH source_raw AS (
    SELECT DISTINCT
        {% for i in range(key_columns | length) %}
        {{ extract_key(
               source_json_column,
               afterState,
               beforeState,
               source_key_paths[i],
               source_key_types[i]
           ) }}                                                          AS {{ key_columns[i] }},
        {% endfor %}

        {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ  AS metadata_time,

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

        CASE
            WHEN metadata_time < MAX(metadata_time) OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 )
            THEN TRUE
            ELSE FALSE
        END                                                              AS is_late_arrival,

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
        {% for i in range(key_columns | length) %}
        {{ target_key(key_columns[i], source_key_types[i]) }},
        {% endfor %}

        {{ target_from_column }}                                         AS dwh_effective_from_tstamp,
        {{ target_to_column }}                                           AS dwh_effective_to_tstamp,
        {{ target_dml_type_column }}                                     AS dwh_latest_dml_type_code,
        {{ target_deleted_flag_column }}                                 AS dwh_is_deleted_flag,

        ROW_NUMBER() OVER (
            PARTITION BY
                {% for i in range(key_columns | length) %}
                {{ target_partition_key(key_columns[i], source_key_types[i]) }}{% if not loop.last %}, {% endif %}
                {% endfor %}
            ORDER BY {{ target_from_column }} ASC
        )                                                                AS record_order

    FROM {{ target_relation }}
),

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
                THEN 'FAIL'
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL'
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp
                THEN 'FAIL'
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
                THEN 'FAIL'
            WHEN t.dwh_is_deleted_flag IS DISTINCT FROM 'Y'
                THEN 'FAIL'
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL'
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL'
            WHEN e.exp_effective_to   <> t.dwh_effective_to_tstamp
                THEN 'FAIL'
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
                THEN 'FAIL'
            WHEN prev_t.dwh_effective_to_tstamp IS DISTINCT FROM
                 TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)
                THEN 'FAIL'
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
    record_order, scenario

{% endset %}

{{ log("=== Generated SQL ===", info=True) }}
{{ log(generated_sql,          info=True) }}
{{ log("=== End SQL ===",      info=True) }}

{% if execute %}
    {% set results    = run_query(generated_sql) %}
    {% set fail_count = results.rows
                        | selectattr("row_result", "ne", "PASS")
                        | list | length %}

    {{ log("[SCD2] Total rows : " ~ results.rows | length, info=True) }}
    {{ log("[SCD2] Fail rows  : " ~ fail_count,            info=True) }}

    {% if fail_count > 0 %}
        {{ log("Connect with data team for refresh", info=True) }}
        {% if raise_error %}
            {{ exceptions.raise_compiler_error(
                "SCD2 CDC validation FAILED for " ~ target_relation
                ~ " — " ~ fail_count ~ " failing row(s). Check dbt.log."
            ) }}
        {% else %}
            {{ log("Warning: validation failed but continuing (raise_error=False).", info=True) }}
        {% endif %}
    {% else %}
        {{ log("SCD2 CDC validation PASSED for " ~ target_relation, info=True) }}
    {% endif %}
{% endif %}

{{ return(generated_sql) }}

{% endmacro %}
