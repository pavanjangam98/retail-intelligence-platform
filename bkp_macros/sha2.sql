{% macro custom_check_scd2_raw_to_foundation(
    model,
    compare_model,
    key_columns,
    source_key_columns,
    target_key_columns,
    source_trim_columns,
    source_from_column,
    source_to_column,
    source_deleted_flag_column,
    source_dml_type_column,
    target_from_column,
    target_to_column,
    target_deleted_flag_column,
    target_dml_type_column,
    look_back=25,
    lag_minutes=60,
    raise_error=False,
    validate_columns=none,
    validate_source_columns=none,
    validate_target_columns=none
) %}

{# =================================================================
   Macro : custom_check_scd2_raw_to_foundation
   Validates SCD Type-2 pipeline from RAW to FOUNDATION layer.
   Single file — no helper macros needed.
   Supports : INSERT / UPDATE / DELETE / LATE ARRIVAL / COLUMN CHECK.

   Column Validation (optional — SHA2 hash comparison)
   ----------------------------------------------------
   validate_columns        : list of alias names for columns to compare
                             e.g. ['STATUS_CODE', 'AMOUNT']
   validate_source_columns : matching source column names (same order).
                             Columns listed in source_trim_columns will
                             have TRIM() applied before hashing.
                             e.g. ['RELATIONSHIP_STATUS', 'AMOUNT']
   validate_target_columns : matching target column names (same order).
                             e.g. ['RELATIONSHIP_STATUS_CODE', 'AMOUNT']

   All three lists must be the same length.
   SHA2 is computed over COALESCE(col::VARCHAR,'') || '|' || ...
   so NULL values are handled consistently on both sides.
   Pass none (or omit) to skip column validation entirely.
================================================================= #}

-- force dbt to register the dependency on compare_model
-- depends_on: {{ ref(compare_model) }}

{# ── Resolve relations from model name strings ── #}
{% set source_relation  = ref(model) %}
{% set compare_relation = ref(compare_model) %}

{# ── Capture current timestamp — guarded so compilation phase is safe ── #}
{% set current_ts = None %}
{% if execute %}
    {% set current_ts_query %}
        SELECT CURRENT_TIMESTAMP AS current_ts
    {% endset %}
    {% set current_ts_result = run_query(current_ts_query) %}
    {% set current_ts = current_ts_result.columns[0].values()[0] %}
{% endif %}

{{ log("=== SCD2 Raw→Foundation Validation Macro Started ===",        info=True) }}
{{ log("Model                      : " ~ model,                       info=True) }}
{{ log("Compare Model              : " ~ compare_model,               info=True) }}
{{ log("Resolved Source Relation   : " ~ source_relation,             info=True) }}
{{ log("Resolved Compare Relation  : " ~ compare_relation,            info=True) }}
{{ log("Key Columns (alias)        : " ~ key_columns,                 info=True) }}
{{ log("Source Key Columns         : " ~ source_key_columns,          info=True) }}
{{ log("Target Key Columns         : " ~ target_key_columns,          info=True) }}
{{ log("Source Trim Columns        : " ~ source_trim_columns,         info=True) }}
{{ log("Source From Column         : " ~ source_from_column,          info=True) }}
{{ log("Source To Column           : " ~ source_to_column,            info=True) }}
{{ log("Source Deleted Flag Column : " ~ source_deleted_flag_column,  info=True) }}
{{ log("Source DML Type Column     : " ~ source_dml_type_column,      info=True) }}
{{ log("Target From Column         : " ~ target_from_column,          info=True) }}
{{ log("Target To Column           : " ~ target_to_column,            info=True) }}
{{ log("Target Deleted Flag Column : " ~ target_deleted_flag_column,  info=True) }}
{{ log("Target DML Type Column     : " ~ target_dml_type_column,      info=True) }}
{{ log("Look Back (days)           : " ~ look_back,                   info=True) }}
{{ log("Lag Minutes                : " ~ lag_minutes,                 info=True) }}
{{ log("Validate Columns           : " ~ validate_columns,            info=True) }}
{{ log("Validate Source Columns    : " ~ validate_source_columns,     info=True) }}
{{ log("Validate Target Columns    : " ~ validate_target_columns,     info=True) }}
{{ log("Current Timestamp          : " ~ current_ts,                  info=True) }}

{# ── Validate key list lengths ── #}
{% if key_columns | length != source_key_columns | length %}
    {{ exceptions.raise_compiler_error(
        "key_columns and source_key_columns must be the same length. Got "
        ~ key_columns | length ~ " key_columns and "
        ~ source_key_columns | length ~ " source_key_columns."
    ) }}
{% endif %}

{% if key_columns | length != target_key_columns | length %}
    {{ exceptions.raise_compiler_error(
        "key_columns and target_key_columns must be the same length. Got "
        ~ key_columns | length ~ " key_columns and "
        ~ target_key_columns | length ~ " target_key_columns."
    ) }}
{% endif %}

{# ── Validate validate_columns lists are consistent ── #}
{% if validate_columns is not none %}
    {% if validate_source_columns is none or validate_target_columns is none %}
        {{ exceptions.raise_compiler_error(
            "validate_source_columns and validate_target_columns are both required when validate_columns is provided."
        ) }}
    {% endif %}
    {% if validate_columns | length != validate_source_columns | length %}
        {{ exceptions.raise_compiler_error(
            "validate_columns and validate_source_columns must be the same length. Got "
            ~ validate_columns | length ~ " vs " ~ validate_source_columns | length ~ "."
        ) }}
    {% endif %}
    {% if validate_columns | length != validate_target_columns | length %}
        {{ exceptions.raise_compiler_error(
            "validate_columns and validate_target_columns must be the same length. Got "
            ~ validate_columns | length ~ " vs " ~ validate_target_columns | length ~ "."
        ) }}
    {% endif %}
{% endif %}

{% set generated_sql %}

WITH source_data AS (
    SELECT
        {# ── Source key columns — apply TRIM() if listed in source_trim_columns ── #}
        {% for i in range(source_key_columns | length) %}
            {% if source_key_columns[i] in source_trim_columns %}
        TRIM({{ source_key_columns[i] }})                                AS {{ key_columns[i] }},
            {% else %}
        {{ source_key_columns[i] }}                                      AS {{ key_columns[i] }},
            {% endif %}
        {% endfor %}

        {# ── Validate columns from source — TRIM if in source_trim_columns ── #}
        {% if validate_columns is not none %}
            {% for i in range(validate_columns | length) %}
                {% if validate_source_columns[i] in source_trim_columns %}
        TRIM({{ validate_source_columns[i] }})                           AS {{ validate_columns[i] }}_src,
                {% else %}
        {{ validate_source_columns[i] }}                                 AS {{ validate_columns[i] }}_src,
                {% endif %}
            {% endfor %}
        {% endif %}

        {{ source_from_column }}                                         AS src_effective_from,
        {{ source_to_column }}                                           AS src_effective_to,
        {{ source_dml_type_column }}                                     AS src_dml_type_code,
        {{ source_deleted_flag_column }}                                 AS src_is_deleted_flag,

        -- Row number per key ordered by effective_from ASC
        ROW_NUMBER() OVER (
            PARTITION BY {{ key_columns | join(', ') }}
            ORDER BY {{ source_from_column }} ASC
        )                                                                AS record_order,

        CASE
            WHEN {{ source_dml_type_column }} = 'D'
             AND {{ source_deleted_flag_column }} = 'Y' THEN 'DELETE'
            WHEN ROW_NUMBER() OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY {{ source_from_column }} ASC
                 ) = 1                                  THEN 'INSERT'
            ELSE 'UPDATE'
        END                                                              AS scenario,

        -- Late arrival: effective_from is earlier than a row
        -- that was already processed for the same key group
        CASE
            WHEN {{ source_from_column }} < MAX({{ source_from_column }}) OVER (
                     PARTITION BY {{ key_columns | join(', ') }}
                     ORDER BY {{ source_from_column }} ASC
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 )
            THEN TRUE
            ELSE FALSE
        END                                                              AS is_late_arrival

    FROM {{ source_relation }}
    WHERE {{ source_from_column }} <= DATEADD(MINUTE, -{{ lag_minutes }}, '{{ current_ts }}'::TIMESTAMP_TZ)
      AND {{ source_from_column }} >= DATEADD(DAY,    -{{ look_back }},   '{{ current_ts }}'::TIMESTAMP_TZ)
),

{# ── SHA2 hash of all validate columns on source side ── #}
{% if validate_columns is not none %}
source_data_hashed AS (
    SELECT
        *,
        SHA2(
            {% for i in range(validate_columns | length) %}
            COALESCE({{ validate_columns[i] }}_src::VARCHAR, '')
            {% if not loop.last %} || '|' || {% endif %}
            {% endfor %}
        )                                                                AS src_validate_sha2
    FROM source_data
),
{% endif %}

target_data AS (
    SELECT
        {# ── Target key columns aliased to match key_columns for clean JOINs ── #}
        {% for i in range(target_key_columns | length) %}
        {{ target_key_columns[i] }}                                      AS {{ key_columns[i] }},
        {% endfor %}

        {# ── Validate columns from target — TRIM if in source_trim_columns (for consistency) ── #}
        {% if validate_columns is not none %}
            {% for i in range(validate_columns | length) %}
                {% if validate_target_columns[i] in source_trim_columns %}
        TRIM({{ validate_target_columns[i] }})                           AS {{ validate_columns[i] }}_tgt,
                {% else %}
        {{ validate_target_columns[i] }}                                 AS {{ validate_columns[i] }}_tgt,
                {% endif %}
            {% endfor %}
        {% endif %}

        {{ target_from_column }}                                         AS tgt_effective_from,
        {{ target_to_column }}                                           AS tgt_effective_to,
        {{ target_dml_type_column }}                                     AS tgt_dml_type_code,
        {{ target_deleted_flag_column }}                                 AS tgt_is_deleted_flag,

        ROW_NUMBER() OVER (
            PARTITION BY
                {# Partition by original target key columns —
                   aliases not resolvable in window functions in Snowflake #}
                {% for col in target_key_columns %}
                {{ col }}{% if not loop.last %}, {% endif %}
                {% endfor %}
            ORDER BY {{ target_from_column }} ASC
        )                                                                AS record_order

    FROM {{ compare_relation }}
    WHERE {{ target_from_column }} <= DATEADD(MINUTE, -{{ lag_minutes }}, '{{ current_ts }}'::TIMESTAMP_TZ)
      AND {{ target_from_column }} >= DATEADD(DAY,    -{{ look_back }},   '{{ current_ts }}'::TIMESTAMP_TZ)
),

{# ── SHA2 hash of all validate columns on target side ── #}
{% if validate_columns is not none %}
target_data_hashed AS (
    SELECT
        *,
        SHA2(
            {% for i in range(validate_columns | length) %}
            COALESCE({{ validate_columns[i] }}_tgt::VARCHAR, '')
            {% if not loop.last %} || '|' || {% endif %}
            {% endfor %}
        )                                                                AS tgt_validate_sha2
    FROM target_data
),
{% endif %}

-- ============================================================
-- CHECK 1 : INSERT and UPDATE (including late arrivals)
-- Validates effective_from, effective_to and SHA2 column hash.
-- ============================================================
insert_update_check AS (
    SELECT
        {% for col in key_columns %}s.{{ col }}, {% endfor %}
        s.record_order,

        -- Label late arrivals distinctly
        CASE
            WHEN s.is_late_arrival = TRUE THEN s.scenario || '_LATE'
            ELSE s.scenario
        END                                                              AS scenario,

        s.src_effective_from,
        s.src_effective_to,
        t.tgt_effective_from,
        t.tgt_effective_to,

        {# ── Expose SHA2 hashes for debugging when column validation enabled ── #}
        {% if validate_columns is not none %}
        s.src_validate_sha2,
        t.tgt_validate_sha2,
        {% endif %}

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Row missing in foundation for record_order '
                     || s.record_order::VARCHAR
            WHEN s.src_effective_from <> t.tgt_effective_from
                THEN 'FAIL - effective_from mismatch (src: '
                     || s.src_effective_from::VARCHAR
                     || ', tgt: ' || t.tgt_effective_from::VARCHAR || ')'
            WHEN s.src_effective_to <> t.tgt_effective_to
                THEN 'FAIL - effective_to mismatch (src: '
                     || s.src_effective_to::VARCHAR
                     || ', tgt: ' || t.tgt_effective_to::VARCHAR || ')'
            {# ── SHA2 hash comparison across all validate columns ── #}
            {% if validate_columns is not none %}
            WHEN s.src_validate_sha2 IS DISTINCT FROM t.tgt_validate_sha2
                THEN 'FAIL - validate_columns SHA2 mismatch (src_sha2: '
                     || COALESCE(s.src_validate_sha2, 'NULL')
                     || ', tgt_sha2: '
                     || COALESCE(t.tgt_validate_sha2, 'NULL') || ')'
            {% endif %}
            ELSE 'PASS'
        END                                                              AS row_result

    FROM {% if validate_columns is not none %}source_data_hashed{% else %}source_data{% endif %} s
    LEFT JOIN {% if validate_columns is not none %}target_data_hashed{% else %}target_data{% endif %} t
        ON  {% for col in key_columns %}
            s.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND s.record_order = t.record_order
    WHERE s.scenario IN ('INSERT', 'UPDATE')
),

-- ============================================================
-- CHECK 2 : DELETE scenario
-- Validates flags, effective_from, effective_to and SHA2 hash.
-- ============================================================
delete_check AS (
    SELECT
        {% for col in key_columns %}s.{{ col }}, {% endfor %}
        s.record_order,
        s.scenario,
        s.src_effective_from,
        s.src_effective_to,
        t.tgt_effective_from,
        t.tgt_effective_to,

        {% if validate_columns is not none %}
        s.src_validate_sha2,
        t.tgt_validate_sha2,
        {% endif %}

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Row missing in foundation for record_order '
                     || s.record_order::VARCHAR
            WHEN t.tgt_is_deleted_flag IS DISTINCT FROM 'Y'
                THEN 'FAIL - tgt_is_deleted_flag is not Y (actual: '
                     || COALESCE(t.tgt_is_deleted_flag, 'NULL') || ')'
            WHEN t.tgt_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL - tgt_dml_type_code is not D (actual: '
                     || COALESCE(t.tgt_dml_type_code, 'NULL') || ')'
            WHEN s.src_effective_from <> t.tgt_effective_from
                THEN 'FAIL - effective_from mismatch (src: '
                     || s.src_effective_from::VARCHAR
                     || ', tgt: ' || t.tgt_effective_from::VARCHAR || ')'
            WHEN s.src_effective_to <> t.tgt_effective_to
                THEN 'FAIL - effective_to mismatch (src: '
                     || s.src_effective_to::VARCHAR
                     || ', tgt: ' || t.tgt_effective_to::VARCHAR || ')'
            {% if validate_columns is not none %}
            WHEN s.src_validate_sha2 IS DISTINCT FROM t.tgt_validate_sha2
                THEN 'FAIL - validate_columns SHA2 mismatch (src_sha2: '
                     || COALESCE(s.src_validate_sha2, 'NULL')
                     || ', tgt_sha2: '
                     || COALESCE(t.tgt_validate_sha2, 'NULL') || ')'
            {% endif %}
            ELSE 'PASS'
        END                                                              AS row_result

    FROM {% if validate_columns is not none %}source_data_hashed{% else %}source_data{% endif %} s
    LEFT JOIN {% if validate_columns is not none %}target_data_hashed{% else %}target_data{% endif %} t
        ON  {% for col in key_columns %}
            s.{{ col }} = t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND s.record_order = t.record_order
    WHERE s.scenario = 'DELETE'
),

-- ============================================================
-- CHECK 3 : Late arrival — prior row back-dating
-- (column check not applicable here — prior row back-dating only)
-- ============================================================
missing_late_check AS (
    SELECT
        {% for col in key_columns %}s.{{ col }}, {% endfor %}
        s.record_order,
        'LATE_PRIOR_ROW_BACKDATE'                                        AS scenario,
        s.src_effective_from,
        s.src_effective_to,
        prev_t.tgt_effective_from,
        prev_t.tgt_effective_to,

        {# ── NULL placeholders to keep UNION ALL column count consistent ── #}
        {% if validate_columns is not none %}
        NULL::VARCHAR                                                     AS src_validate_sha2,
        NULL::VARCHAR                                                     AS tgt_validate_sha2,
        {% endif %}

        CASE
            WHEN prev_t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Prior foundation row not found for record_order '
                     || (s.record_order - 1)::VARCHAR
            WHEN prev_t.tgt_effective_to IS DISTINCT FROM
                 TIMESTAMPADD(MICROSECOND, -1, s.src_effective_from)
                THEN 'FAIL - Prior row not back-dated (exp: '
                     || TIMESTAMPADD(MICROSECOND, -1, s.src_effective_from)::VARCHAR
                     || ', act: ' || prev_t.tgt_effective_to::VARCHAR || ')'
            ELSE 'PASS'
        END                                                              AS row_result

    FROM {% if validate_columns is not none %}source_data_hashed{% else %}source_data{% endif %} s
    LEFT JOIN {% if validate_columns is not none %}target_data_hashed{% else %}target_data{% endif %} prev_t
        ON  {% for col in key_columns %}
            s.{{ col }} = prev_t.{{ col }}{% if not loop.last %} AND {% endif %}
            {% endfor %}
        AND prev_t.record_order = s.record_order - 1
    WHERE s.is_late_arrival = TRUE
      AND s.scenario <> 'DELETE'
)

-- Return ONLY failing rows so dbt marks test as PASS when 0 rows returned
SELECT * FROM (
    SELECT * FROM insert_update_check
    UNION ALL
    SELECT * FROM delete_check
    UNION ALL
    SELECT * FROM missing_late_check
) all_checks
WHERE row_result <> 'PASS'

ORDER BY
    {% for col in key_columns %}{{ col }}, {% endfor %}
    record_order, scenario

{% endset %}

{{ log("=== Generated SCD2 Raw→Foundation Validation SQL ===", info=True) }}
{{ log(generated_sql,                                          info=True) }}
{{ log("=== End of Generated SQL ===",                         info=True) }}

{% if execute %}
    {% set results    = run_query(generated_sql) %}
    {% set fail_count = results.rows | length %}

    {{ log("[SCD2 Raw→Fnd] Total failing rows : " ~ fail_count, info=True) }}

    {% if fail_count > 0 %}
        {{ log("Connect with data team for refresh", info=True) }}
        {% if raise_error %}
            {{ exceptions.raise_compiler_error(
                "SCD2 Raw→Foundation validation FAILED for "
                ~ compare_relation ~ " — "
                ~ fail_count ~ " failing row(s) found in the last "
                ~ look_back ~ " day(s). Check dbt.log for details."
            ) }}
        {% else %}
            {{ log("Warning: validation failed but continuing (raise_error=False).", info=True) }}
        {% endif %}
    {% else %}
        {{ log("SCD2 Raw→Foundation validation PASSED for "
               ~ compare_relation
               ~ " (last " ~ look_back ~ " day(s))", info=True) }}
    {% endif %}
{% endif %}

{{ return(generated_sql) }}

{% endmacro %}


{# =================================================================
   USAGE EXAMPLE — WITHOUT column validation (original behaviour)
   Save as: macros/custom_check_scd2_raw_to_foundation.sql
================================================================= #}

{#
{{ custom_check_scd2_raw_to_foundation(
    model                      = 'raw___bis___bst_cust_reln',
    compare_model              = 'foundation___fdp__custmstr___fdp__party_relationship',

    key_columns                = ['CUSTOMER_ID', 'RELATIONSHIP_TYPE_CODE',
                                  'RELATIONSHIP_CODE', 'RELATED_CUSTOMER_ID'],
    source_key_columns         = ['CUSTOMER1_NO', 'RELATIONSHIP_TYPE',
                                  'RELATIONSHIP_CODE', 'CUSTOMER2_NO'],
    target_key_columns         = ['CUSTOMER_ID', 'RELATIONSHIP_TYPE_CODE',
                                  'RELATIONSHIP_CODE', 'RELATED_CUSTOMER_ID'],
    source_trim_columns        = ['RELATIONSHIP_TYPE', 'RELATIONSHIP_CODE'],

    source_from_column         = 'DWH_EFFECTIVE_FROM_TSTAMP',
    source_to_column           = 'DWH_EFFECTIVE_TO_TSTAMP',
    source_deleted_flag_column = 'DWH_IS_DELETED_FLAG',
    source_dml_type_column     = 'DWH_LATEST_DML_TYPE_CODE',

    target_from_column         = 'DWH_EFFECTIVE_FROM_TSTAMP',
    target_to_column           = 'DWH_EFFECTIVE_TO_TSTAMP',
    target_deleted_flag_column = 'DWH_IS_DELETED_FLAG',
    target_dml_type_column     = 'DWH_LATEST_DML_TYPE_CODE',

    look_back                  = 25,
    lag_minutes                = 60,
    raise_error                = False
) }}
#}


{# =================================================================
   USAGE EXAMPLE — WITH multi-column SHA2 validation
   SHA2 is computed over STATUS_CODE and AMOUNT on both sides.
   Columns in source_trim_columns are TRIMmed before hashing.

   -- source_trim_columns includes RELATIONSHIP_TYPE → TRIMmed on both sides
   -- validate_columns       : aliases shown in FAIL messages / output
   -- validate_source_columns: actual column names in RAW model
   -- validate_target_columns: actual column names in FOUNDATION model
================================================================= #}

{#
{{ custom_check_scd2_raw_to_foundation(
    model                      = 'raw___bis___bst_cust_reln',
    compare_model              = 'foundation___fdp__custmstr___fdp__party_relationship',

    key_columns                = ['CUSTOMER_ID', 'RELATIONSHIP_TYPE_CODE',
                                  'RELATIONSHIP_CODE', 'RELATED_CUSTOMER_ID'],
    source_key_columns         = ['CUSTOMER1_NO', 'RELATIONSHIP_TYPE',
                                  'RELATIONSHIP_CODE', 'CUSTOMER2_NO'],
    target_key_columns         = ['CUSTOMER_ID', 'RELATIONSHIP_TYPE_CODE',
                                  'RELATIONSHIP_CODE', 'RELATED_CUSTOMER_ID'],
    source_trim_columns        = ['RELATIONSHIP_TYPE', 'RELATIONSHIP_CODE'],

    source_from_column         = 'DWH_EFFECTIVE_FROM_TSTAMP',
    source_to_column           = 'DWH_EFFECTIVE_TO_TSTAMP',
    source_deleted_flag_column = 'DWH_IS_DELETED_FLAG',
    source_dml_type_column     = 'DWH_LATEST_DML_TYPE_CODE',

    target_from_column         = 'DWH_EFFECTIVE_FROM_TSTAMP',
    target_to_column           = 'DWH_EFFECTIVE_TO_TSTAMP',
    target_deleted_flag_column = 'DWH_IS_DELETED_FLAG',
    target_dml_type_column     = 'DWH_LATEST_DML_TYPE_CODE',

    look_back                  = 25,
    lag_minutes                = 60,
    raise_error                = False,

    -- Multi-column SHA2 validation (omit all three to skip)
    validate_columns           = ['STATUS_CODE', 'AMOUNT'],
    validate_source_columns    = ['RELATIONSHIP_STATUS', 'AMOUNT'],
    validate_target_columns    = ['RELATIONSHIP_STATUS_CODE', 'AMOUNT']
) }}
#}


{# =================================================================
   USAGE EXAMPLE — Airflow DbtRunOperationOperator
   WITHOUT column validation
================================================================= #}

{#
scd2_validation_raw_to_foundation = DbtRunOperationOperator(
    task_id="run_custom_check_scd2_raw_to_foundation",
    macro_name="custom_check_scd2_raw_to_foundation",
    project_dir=project_path,
    profile_config=profile_config,
    args={
        "model":                      "raw___bis___bst_cust_reln",
        "compare_model":              "foundation___fdp__custmstr___fdp__party_relationship",
        "key_columns":                ["CUSTOMER_ID", "RELATIONSHIP_TYPE_CODE",
                                       "RELATIONSHIP_CODE", "RELATED_CUSTOMER_ID"],
        "source_key_columns":         ["CUSTOMER1_NO", "RELATIONSHIP_TYPE",
                                       "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
        "target_key_columns":         ["CUSTOMER_ID", "RELATIONSHIP_TYPE_CODE",
                                       "RELATIONSHIP_CODE", "RELATED_CUSTOMER_ID"],
        "source_trim_columns":        ["RELATIONSHIP_TYPE", "RELATIONSHIP_CODE"],
        "source_from_column":         "DWH_EFFECTIVE_FROM_TSTAMP",
        "source_to_column":           "DWH_EFFECTIVE_TO_TSTAMP",
        "source_deleted_flag_column": "DWH_IS_DELETED_FLAG",
        "source_dml_type_column":     "DWH_LATEST_DML_TYPE_CODE",
        "target_from_column":         "DWH_EFFECTIVE_FROM_TSTAMP",
        "target_to_column":           "DWH_EFFECTIVE_TO_TSTAMP",
        "target_deleted_flag_column": "DWH_IS_DELETED_FLAG",
        "target_dml_type_column":     "DWH_LATEST_DML_TYPE_CODE",
        "look_back":                  look_back,
        "raise_error":                "True",
    },
    dbt_executable_path=dbt_executable_path,
)
#}


{# =================================================================
   USAGE EXAMPLE — Airflow DbtRunOperationOperator
   WITH multi-column SHA2 validation
================================================================= #}

{#
scd2_validation_raw_to_foundation = DbtRunOperationOperator(
    task_id="run_custom_check_scd2_raw_to_foundation",
    macro_name="custom_check_scd2_raw_to_foundation",
    project_dir=project_path,
    profile_config=profile_config,
    args={
        "model":                      "raw___bis___bst_cust_reln",
        "compare_model":              "foundation___fdp__custmstr___fdp__party_relationship",
        "key_columns":                ["CUSTOMER_ID", "RELATIONSHIP_TYPE_CODE",
                                       "RELATIONSHIP_CODE", "RELATED_CUSTOMER_ID"],
        "source_key_columns":         ["CUSTOMER1_NO", "RELATIONSHIP_TYPE",
                                       "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
        "target_key_columns":         ["CUSTOMER_ID", "RELATIONSHIP_TYPE_CODE",
                                       "RELATIONSHIP_CODE", "RELATED_CUSTOMER_ID"],
        "source_trim_columns":        ["RELATIONSHIP_TYPE", "RELATIONSHIP_CODE"],
        "source_from_column":         "DWH_EFFECTIVE_FROM_TSTAMP",
        "source_to_column":           "DWH_EFFECTIVE_TO_TSTAMP",
        "source_deleted_flag_column": "DWH_IS_DELETED_FLAG",
        "source_dml_type_column":     "DWH_LATEST_DML_TYPE_CODE",
        "target_from_column":         "DWH_EFFECTIVE_FROM_TSTAMP",
        "target_to_column":           "DWH_EFFECTIVE_TO_TSTAMP",
        "target_deleted_flag_column": "DWH_IS_DELETED_FLAG",
        "target_dml_type_column":     "DWH_LATEST_DML_TYPE_CODE",
        "look_back":                  look_back,
        "raise_error":                "True",
        "validate_columns":           ["STATUS_CODE", "AMOUNT"],
        "validate_source_columns":    ["RELATIONSHIP_STATUS", "AMOUNT"],
        "validate_target_columns":    ["RELATIONSHIP_STATUS_CODE", "AMOUNT"],
    },
    dbt_executable_path=dbt_executable_path,
)
#}
