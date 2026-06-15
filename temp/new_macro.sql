{#
    MACRO: compare_src_tgt_scd2
    -----------------------------------
    Generic source-vs-target reconciliation for any SCD2 (history) table.

    For each source record it:
      1. Recomputes the EXPECTED effective_from / effective_to using the
         same LEAD() logic used to build SCD2 history
         (effective_to = next record's start - 1 microsecond, or 9999-12-31
          if it's the latest record).
      2. Classifies the record as INSERT (record_order = 1), UPDATE, or
         DELETE (based on source delete flag).
      3. Joins to the matching target row (business_key + effective_from).
      4. Compares EVERY column in `compare_columns` between source and
         target and returns an array of any columns that don't match.
      5. Rolls everything up into a single final_result (PASS / FAIL + reason).

    Params:
        source_relation   : table/view OR a parenthesised subquery string,
                             e.g. "(" ~ my_flatten_sql ~ ")"
                             Must expose: business_key col, source_time_col,
                             every column listed in compare_columns, and
                             (optionally) source_is_deleted_col.
        target_relation   : ref() to the target SCD2 table.
        business_key      : column name (same name in source & target) that
                             identifies the entity, e.g. 'customer_no'.
        source_time_col   : column in source that drives effective_from,
                             e.g. 'metadata_time'.
        compare_columns   : list of attribute column names to diff,
                             e.g. ['short_name','legal_name','branch_no', ...]
                             (same names must exist in source & target).
        effective_from_col: target column name, default 'dwh_effective_from_tstamp'
        effective_to_col  : target column name, default 'dwh_effective_to_tstamp'
        is_deleted_col    : target column name, default 'dwh_is_deleted_flag'
        source_is_deleted_col : source column expressing 'Y'/'N' delete flag.
                             If none, source is assumed never-deleted ('N').

    Output columns:
        <business_key>, record_order, expected_scenario,
        exp_effective_from, exp_effective_to,
        act_effective_from, act_effective_to,
        chk_effective_from, chk_effective_to, chk_deleted_flag,
        mismatched_columns   (ARRAY - empty if all attributes match),
        final_result         ('PASS' or 'FAIL - <reason>')
#}

{% macro compare_src_tgt_scd2(
    source_relation,
    target_relation,
    business_key,
    source_time_col,
    compare_columns,
    effective_from_col='dwh_effective_from_tstamp',
    effective_to_col='dwh_effective_to_tstamp',
    is_deleted_col='dwh_is_deleted_flag',
    source_is_deleted_col=none
) %}

WITH source_data AS (

    SELECT
        {{ business_key }}::VARCHAR AS business_key,
        {{ source_time_col }}::TIMESTAMP_NTZ AS src_effective_from,
        {% for col in compare_columns %}
        {{ col }} AS src_{{ col }},
        {% endfor %}
        {% if source_is_deleted_col %}
        {{ source_is_deleted_col }} AS src_is_deleted_flag
        {% else %}
        'N' AS src_is_deleted_flag
        {% endif %}
    FROM {{ source_relation }}
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY {{ business_key }}, {{ source_time_col }}
        ORDER BY {{ source_time_col }} DESC) = 1

),

expected AS (

    SELECT
        *,
        TIMESTAMPADD(MICROSECOND, -1,
            COALESCE(
                LEAD(src_effective_from) OVER (PARTITION BY business_key ORDER BY src_effective_from ASC),
                '9999-12-31T00:00:00.000001'::TIMESTAMP_NTZ
            )
        ) AS exp_effective_to,
        ROW_NUMBER() OVER (PARTITION BY business_key ORDER BY src_effective_from ASC) AS record_order,
        CASE
            WHEN ROW_NUMBER() OVER (PARTITION BY business_key ORDER BY src_effective_from ASC) = 1 THEN 'INSERT'
            WHEN src_is_deleted_flag = 'Y' THEN 'DELETE'
            ELSE 'UPDATE'
        END AS expected_scenario
    FROM source_data

),

target_data AS (

    SELECT
        {{ business_key }}::VARCHAR AS business_key,
        {{ effective_from_col }} AS act_effective_from,
        {{ effective_to_col }}   AS act_effective_to,
        {{ is_deleted_col }}     AS act_is_deleted_flag,
        {% for col in compare_columns %}
        {{ col }} AS tgt_{{ col }}{{ "," if not loop.last }}
        {% endfor %}
    FROM {{ target_relation }}

)

SELECT
    e.business_key AS {{ business_key }},
    e.record_order,
    e.expected_scenario,

    e.src_effective_from AS exp_effective_from,
    e.exp_effective_to,
    t.act_effective_from,
    t.act_effective_to,

    CASE WHEN t.business_key IS NULL THEN 'FAIL - Not Found'
         WHEN e.src_effective_from = t.act_effective_from THEN 'PASS'
         ELSE 'FAIL' END AS chk_effective_from,

    CASE WHEN t.business_key IS NULL THEN 'FAIL - Not Found'
         WHEN e.exp_effective_to = t.act_effective_to THEN 'PASS'
         ELSE 'FAIL' END AS chk_effective_to,

    CASE WHEN t.business_key IS NULL THEN 'FAIL - Not Found'
         WHEN e.src_is_deleted_flag = t.act_is_deleted_flag THEN 'PASS'
         ELSE 'FAIL' END AS chk_deleted_flag,

    -- Names of every attribute column where source <> target
    ARRAY_CONSTRUCT_COMPACT(
        {% for col in compare_columns %}
        CASE WHEN e.src_{{ col }} IS DISTINCT FROM t.tgt_{{ col }} THEN '{{ col }}' END{{ "," if not loop.last }}
        {% endfor %}
    ) AS mismatched_columns,

    CASE
        WHEN t.business_key IS NULL THEN 'FAIL - Missing In Target'
        WHEN e.src_effective_from <> t.act_effective_from THEN 'FAIL - Effective From Mismatch'
        WHEN e.exp_effective_to   <> t.act_effective_to   THEN 'FAIL - Effective To Mismatch'
        WHEN e.src_is_deleted_flag <> t.act_is_deleted_flag THEN 'FAIL - Deleted Flag Mismatch'
        WHEN ARRAY_SIZE(ARRAY_CONSTRUCT_COMPACT(
            {% for col in compare_columns %}
            CASE WHEN e.src_{{ col }} IS DISTINCT FROM t.tgt_{{ col }} THEN '{{ col }}' END{{ "," if not loop.last }}
            {% endfor %}
        )) > 0 THEN 'FAIL - Attribute Mismatch'
        ELSE 'PASS'
    END AS final_result

FROM expected e
LEFT JOIN target_data t
    ON  e.business_key = t.business_key
    AND e.src_effective_from = t.act_effective_from

ORDER BY e.business_key, e.record_order

{% endmacro %}
