{% macro test_scd2_validation(
    source_relation,
    target_relation,
    key_columns,
    source_json_column,
    source_key_paths,
    source_time_path,
    target_from_column,
    target_to_column
) %}

{{ log("=== SCD2 Validation Macro Started ===", info=True) }}
{{ log("Source Relation: " ~ source_relation, info=True) }}
{{ log("Target Relation: " ~ target_relation, info=True) }}
{{ log("Key Columns: " ~ key_columns, info=True) }}
{{ log("Source Key Paths: " ~ source_key_paths, info=True) }}
{{ log("Source JSON Column: " ~ source_json_column, info=True) }}
{{ log("Source Time Path: " ~ source_time_path, info=True) }}
{{ log("Target From Column: " ~ target_from_column, info=True) }}
{{ log("Target To Column: " ~ target_to_column, info=True) }}

{% if key_columns | length != source_key_paths | length %}
    {{ exceptions.raise_compiler_error(
        "key_columns and source_key_paths must be the same length. Got "
        ~ key_columns | length ~ " key_columns and " ~ source_key_paths | length ~ " source_key_paths."
    ) }}
{% endif %}

{% set generated_sql %}

WITH source_raw AS (

    SELECT
        {% for col in key_columns %}
            {{ source_json_column }}:{{ source_key_paths[loop.index0] }}::NUMBER AS {{ col }},
        {% endfor %}
        {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ AS metadata_time
    FROM {{ source_relation }}
    WHERE
        {% for col in key_columns %}
            {{ source_json_column }}:{{ source_key_paths[loop.index0] }} IS NOT NULL
            {% if not loop.last %} AND {% endif %}
        {% endfor %}

),

source_dedup AS (
    SELECT DISTINCT
        {% for col in key_columns %}
            {{ col }},
        {% endfor %}
        metadata_time
    FROM source_raw
),

source_expected AS (
    SELECT
        {% for col in key_columns %}
            {{ col }},
        {% endfor %}
        metadata_time                                                  AS exp_effective_from,

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

        ROW_NUMBER() OVER (
            PARTITION BY {{ key_columns | join(', ') }}
            ORDER BY metadata_time ASC
        )                                                               AS record_order,

        CASE
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY metadata_time ASC
                 ) = 1
            THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                             AS scenario

    FROM source_dedup
),

target_data AS (
    SELECT
        {% for col in key_columns %}
            {{ col }},
        {% endfor %}
        {{ target_from_column }}                                       AS dwh_effective_from_tstamp,
        {{ target_to_column }}                                         AS dwh_effective_to_tstamp,
        ROW_NUMBER() OVER (
            PARTITION BY {{ key_columns | join(', ') }}
            ORDER BY {{ target_from_column }} ASC
        )                                                               AS record_order
    FROM {{ target_relation }}
),

row_counts AS (
    SELECT
        {% for col in key_columns %}
            s.{{ col }},
        {% endfor %}
        COUNT(DISTINCT s.record_order)                                 AS src_version_count,
        COUNT(DISTINCT t.record_order)                                 AS tgt_version_count
    FROM source_expected s
    LEFT JOIN target_data t
        ON {% for col in key_columns %} t.{{ col }} = s.{{ col }}{% if not loop.last %} AND {% endif %}{% endfor %}
    GROUP BY
        {% for col in key_columns %}
            s.{{ col }}{% if not loop.last %}, {% endif %}
        {% endfor %}
),

main_check AS (
    SELECT
        {% for col in key_columns %}
            e.{{ col }},
        {% endfor %}
        e.record_order,
        e.scenario,
        e.exp_effective_from,
        e.exp_effective_to,
        t.dwh_effective_from_tstamp                                     AS act_effective_from,
        t.dwh_effective_to_tstamp                                       AS act_effective_to,
        rc.src_version_count,
        rc.tgt_version_count,

        CASE WHEN t.{{ key_columns[0] }} IS NULL THEN 'FAIL'
             ELSE 'PASS' END                                            AS chk_row_exists,

        CASE WHEN t.{{ key_columns[0] }} IS NULL THEN 'N/A'
             WHEN e.exp_effective_from = t.dwh_effective_from_tstamp THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_effective_from,

        CASE WHEN t.{{ key_columns[0] }} IS NULL THEN 'N/A'
             WHEN e.exp_effective_to = t.dwh_effective_to_tstamp THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_effective_to,

        CASE WHEN rc.src_version_count = rc.tgt_version_count THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_version_count,

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
        END                                                              AS final_result

    FROM source_expected e
    LEFT JOIN target_data t
        ON {% for col in key_columns %} e.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}{% endfor %}
        AND e.record_order = t.record_order
    LEFT JOIN row_counts rc
        ON {% for col in key_columns %} rc.{{ col }} = e.{{ col }}{% if not loop.last %} AND {% endif %}{% endfor %}
),

orphan_check AS (
    SELECT
        {% for col in key_columns %}
            t.{{ col }},
        {% endfor %}
        t.record_order,
        'ORPHAN_TARGET_ROW'                                            AS scenario,
        NULL                                                            AS exp_effective_from,
        NULL                                                            AS exp_effective_to,
        t.dwh_effective_from_tstamp                                    AS act_effective_from,
        t.dwh_effective_to_tstamp                                      AS act_effective_to,
        rc.src_version_count,
        rc.tgt_version_count,
        'N/A'                                                          AS chk_row_exists,
        'N/A'                                                          AS chk_effective_from,
        'N/A'                                                          AS chk_effective_to,
        CASE WHEN rc.src_version_count = rc.tgt_version_count THEN 'PASS'
             ELSE 'FAIL' END                                            AS chk_version_count,
        'FAIL - Extra row in target not present in source (record_order '
            || t.record_order::VARCHAR || ')'                          AS final_result
    FROM target_data t
    LEFT JOIN source_expected e
        ON {% for col in key_columns %} e.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}{% endfor %}
        AND e.record_order = t.record_order
    LEFT JOIN row_counts rc
        ON {% for col in key_columns %} rc.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}{% endfor %}
    WHERE e.{{ key_columns[0] }} IS NULL
),

all_results AS (
    SELECT * FROM main_check
    UNION ALL
    SELECT * FROM orphan_check
)

SELECT *
FROM all_results
WHERE final_result <> 'PASS'

{% endset %}

{{ log("=== Generated SCD2 Validation SQL ===", info=True) }}
{{ log(generated_sql, info=True) }}
{{ log("=== End of Generated SQL ===", info=True) }}

{{ return(generated_sql) }}

{% endmacro %}
