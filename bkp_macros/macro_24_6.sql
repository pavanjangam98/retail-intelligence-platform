{% macro test_scd2_cdc_validation(
    model,
    source_name,
    table_name,
    key_columns,
    source_json_column,
    source_key_paths,
    source_key_types,
    source_time_path,
    target_from_column,
    target_to_column,
    target_deleted_flag_column,
    target_dml_type_column,
    ingestion_type="kafka",
    load_type="type2",
    afterState="afterState",
    beforeState="beforeState",
    look_back=25,
    lag_minutes=60,
    raise_error=False,
    validate_column=none,
    validate_column_path=none,
    validate_column_type="TRIM_VARCHAR",
    target_validate_column=none
) %}

{# =================================================================
   Macro : test_scd2_cdc_validation
   Validates SCD Type-2 CDC pipeline from LANDING to RAW layer.
   Single file — no helper macros needed.
   Supports : INSERT / UPDATE / DELETE / LATE ARRIVAL / COLUMN CHECK.

   Parameters
   ----------
   model                      : raw dbt model name (string, resolved
                                via ref() inside this macro)
                                e.g. 'raw___bis___bst_cust_reln'
   source_name                : dbt source name for landing table
                                e.g. 'landing__bis'
   table_name                 : table name within that source
                                e.g. 'BST_CUST_RELN'
   key_columns                : business key column names (list)
                                e.g. ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                      'RELATIONSHIP_CODE','CUSTOMER2_NO']
   source_json_column         : variant/JSON column in landing
                                e.g. 'RECORD_CONTENT'
   source_key_paths           : JSON sub-paths for each key inside
                                afterState / beforeState (same order
                                as key_columns)
                                e.g. ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                      'RELATIONSHIP_CODE','CUSTOMER2_NO']
   source_key_types           : cast type per key column (same order).
                                All JSON values extracted as strings,
                                so use VARCHAR types for all keys even
                                if the column is NUMBER in the table —
                                filter values should be passed as
                                strings too (e.g. '125468' not 125468).
                                'VARCHAR'      → TRIM(::VARCHAR, '"')
                                                 removes surrounding quotes
                                'TRIM_VARCHAR' → TRIM(TRIM(::VARCHAR,'"'))
                                                 removes quotes + whitespace
                                'NUMBER'       → ::NUMBER
                                                 use only if downstream
                                                 join requires numeric type
                                e.g. ['VARCHAR','TRIM_VARCHAR',
                                      'TRIM_VARCHAR','VARCHAR']
   source_time_path           : JSON path to event timestamp
                                e.g. 'metadata:time'
   target_from_column         : effective_from col in raw target
                                e.g. 'dwh_effective_from_tstamp'
   target_to_column           : effective_to col in raw target
                                e.g. 'dwh_effective_to_tstamp'
   target_deleted_flag_column : deleted flag col in raw target
                                e.g. 'dwh_is_deleted_flag'
   target_dml_type_column     : DML type col in raw target
                                e.g. 'dwh_latest_dml_type_code'
   afterState                 : JSON key for after-image
                                (default 'afterState')
   beforeState                : JSON key for before-image
                                (default 'beforeState')
   look_back                  : days to look back (default 25)
   lag_minutes                : lag in minutes to skip recent
                                unprocessed data (default 60)
   ingestion_type             : ingestion pattern (default 'kafka')
   load_type                  : load strategy — 'type2' or 'append'
                                (default 'type2')
   raise_error                : raise compiler error on failure
                                (default False)
   validate_column            : optional non-key column alias to
                                extract from JSON and compare to target
                                e.g. 'RELATIONSHIP_STATUS'
                                pass none to skip column check
   validate_column_path       : JSON path for validate_column inside
                                afterState / beforeState
                                e.g. 'RELATIONSHIP_STATUS'
   validate_column_type       : cast type for validate_column
                                same options as source_key_types
                                (default 'TRIM_VARCHAR')
   target_validate_column     : actual column name in target table
                                (may differ from validate_column alias)
                                e.g. 'RELATIONSHIP_STATUS_CODE'
                                if same as validate_column, pass the
                                same value or leave as none to auto-use
                                validate_column name
================================================================= #}

{{ log("=== SCD2 CDC Validation (Landing → Raw) Started ===",     info=True) }}

{# ── Resolve relations from model name and source/table strings ── #}
{% set target_relation = ref(model) %}
{% set source_relation = source(source_name, table_name) %}

{{ log("Model (Raw)                : " ~ model,                   info=True) }}
{{ log("Source Name                : " ~ source_name,             info=True) }}
{{ log("Table Name                 : " ~ table_name,              info=True) }}
{{ log("Resolved Source Relation   : " ~ source_relation,         info=True) }}
{{ log("Resolved Target Relation   : " ~ target_relation,         info=True) }}
{{ log("Ingestion Type             : " ~ ingestion_type,          info=True) }}
{{ log("Load Type                  : " ~ load_type,               info=True) }}
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
{{ log("Validate Column            : " ~ validate_column,         info=True) }}
{{ log("Validate Column Path       : " ~ validate_column_path,    info=True) }}
{{ log("Validate Column Type       : " ~ validate_column_type,    info=True) }}
{{ log("Target Validate Column     : " ~ target_validate_column,  info=True) }}

{# ── Validate ingestion_type and load_type ── #}
{% if ingestion_type != "kafka" %}
    {{ exceptions.raise_compiler_error("Unsupported ingestion_type: " ~ ingestion_type) }}
{% endif %}
{% if load_type not in ["type2", "append"] %}
    {{ exceptions.raise_compiler_error("Unsupported load_type: " ~ load_type) }}
{% endif %}

{# ── Validate list lengths ── #}
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

{# ── Validate column check params are consistent ── #}
{% if validate_column is not none and validate_column_path is none %}
    {{ exceptions.raise_compiler_error(
        "validate_column_path is required when validate_column is provided."
    ) }}
{% endif %}

{# ── Resolve target_validate_column: default to validate_column if not provided ── #}
{% if validate_column is not none and target_validate_column is none %}
    {% set target_validate_column = validate_column %}
{% endif %}

{# ── Capture current timestamp once ── #}
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
        {# ── Key columns: JSON extraction inlined ──
           VARCHAR      → TRIM(IFF(...)::VARCHAR, '"')
           TRIM_VARCHAR → TRIM(TRIM(IFF(...)::VARCHAR, '"'))
           NUMBER       → IFF(...)::NUMBER                  #}
        {% for i in range(key_columns | length) %}
            {% set col   = key_columns[i] %}
            {% set path  = source_key_paths[i] %}
            {% set ktype = source_key_types[i] %}
            {% if ktype == 'NUMBER' %}
        IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::NUMBER                                                        AS {{ col }},
            {% elif ktype == 'VARCHAR' %}
        TRIM(IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::VARCHAR, '"')                                                 AS {{ col }},
            {% elif ktype == 'TRIM_VARCHAR' %}
        TRIM(TRIM(IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::VARCHAR, '"'))                                                AS {{ col }},
            {% else %}
        IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ path }},
            {{ source_json_column }}:{{ afterState }}:{{ path }}
        )::VARCHAR                                                       AS {{ col }},
            {% endif %}
        {% endfor %}

        {# ── Optional non-key column: same JSON extraction pattern ── #}
        {% if validate_column is not none %}
            {% if validate_column_type == 'NUMBER' %}
        IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ validate_column_path }},
            {{ source_json_column }}:{{ afterState }}:{{ validate_column_path }}
        )::NUMBER                                                        AS {{ validate_column }},
            {% elif validate_column_type == 'VARCHAR' %}
        TRIM(IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ validate_column_path }},
            {{ source_json_column }}:{{ afterState }}:{{ validate_column_path }}
        )::VARCHAR, '"')                                                 AS {{ validate_column }},
            {% else %}{# default TRIM_VARCHAR #}
        TRIM(TRIM(IFF(
            TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE',
            {{ source_json_column }}:{{ beforeState }}:{{ validate_column_path }},
            {{ source_json_column }}:{{ afterState }}:{{ validate_column_path }}
        )::VARCHAR, '"'))                                                AS {{ validate_column }},
            {% endif %}
        {% endif %}

        {# ── Event timestamp ── #}
        {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ  AS metadata_time,

        {# ── Delete event: afterState = NULL_VALUE + beforeState = OBJECT ── #}
        CASE
            WHEN TYPEOF({{ source_json_column }}:{{ afterState }}) = 'NULL_VALUE'
             AND TYPEOF({{ source_json_column }}:{{ beforeState }}) = 'OBJECT'
            THEN TRUE
            ELSE FALSE
        END                                                              AS is_delete_event

    FROM {{ source_relation }}

    WHERE {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ
              <= DATEADD(MINUTE, -{{ lag_minutes }}, '{{ current_ts }}'::TIMESTAMP_TZ)
      AND {{ source_json_column }}:{{ source_time_path }}::TIMESTAMP_NTZ
              >= DATEADD(DAY,    -{{ look_back }},   '{{ current_ts }}'::TIMESTAMP_TZ)
),

source_dedup AS (
    SELECT DISTINCT
        {% for col in key_columns %}{{ col }}, {% endfor %}
        {% if validate_column is not none %}{{ validate_column }}, {% endif %}
        metadata_time,
        is_delete_event
    FROM source_raw
),

source_expected AS (
    SELECT
        {% for col in key_columns %}{{ col }}, {% endfor %}
        {% if validate_column is not none %}{{ validate_column }}, {% endif %}

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
        {# ── Target key columns: cast to VARCHAR to match source JSON extraction ── #}
        {% for i in range(key_columns | length) %}
            {% set col   = key_columns[i] %}
            {% set ktype = source_key_types[i] %}
            {% if ktype == 'TRIM_VARCHAR' %}
        TRIM({{ col }}::VARCHAR)                                         AS {{ col }},
            {% elif ktype == 'VARCHAR' %}
        {{ col }}::VARCHAR                                               AS {{ col }},
            {% else %}
        {{ col }},
            {% endif %}
        {% endfor %}

        {# ── Optional non-key column from target (may have different name) ── #}
        {% if validate_column is not none %}
        {{ target_validate_column }}                                     AS {{ validate_column }},
        {% endif %}

        {{ target_from_column }}                                         AS dwh_effective_from_tstamp,
        {{ target_to_column }}                                           AS dwh_effective_to_tstamp,
        {{ target_dml_type_column }}                                     AS dwh_latest_dml_type_code,
        {{ target_deleted_flag_column }}                                 AS dwh_is_deleted_flag,

        ROW_NUMBER() OVER (
            PARTITION BY
                {# Must use same expression as SELECT — aliases not
                   resolvable in window functions in Snowflake       #}
                {% for i in range(key_columns | length) %}
                    {% set col   = key_columns[i] %}
                    {% set ktype = source_key_types[i] %}
                    {% if ktype == 'TRIM_VARCHAR' %}
                TRIM({{ col }}::VARCHAR){% if not loop.last %}, {% endif %}
                    {% elif ktype == 'VARCHAR' %}
                {{ col }}::VARCHAR{% if not loop.last %}, {% endif %}
                    {% else %}
                {{ col }}{% if not loop.last %}, {% endif %}
                    {% endif %}
                {% endfor %}
            ORDER BY {{ target_from_column }} ASC
        )                                                                AS record_order

    FROM {{ target_relation }}
),

-- ============================================================
-- CHECK 1 : INSERT and UPDATE (including late arrivals)
-- Validates effective_from, effective_to and optional column.
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

        {# ── Expose source and target values of non-key column for debugging ── #}
        {% if validate_column is not none %}
        e.{{ validate_column }}                                          AS src_{{ validate_column }},
        t.{{ validate_column }}                                          AS tgt_{{ validate_column }},
        {% endif %}

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Row missing in target for record_order '
                     || e.record_order::VARCHAR
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL - effective_from mismatch (exp: '
                     || e.exp_effective_from::VARCHAR
                     || ', act: ' || t.dwh_effective_from_tstamp::VARCHAR || ')'
            WHEN e.exp_effective_to <> t.dwh_effective_to_tstamp
                THEN 'FAIL - effective_to mismatch (exp: '
                     || e.exp_effective_to::VARCHAR
                     || ', act: ' || t.dwh_effective_to_tstamp::VARCHAR || ')'
            {# ── Optional column exact match check ── #}
            {% if validate_column is not none %}
            WHEN e.{{ validate_column }} IS DISTINCT FROM t.{{ validate_column }}
                THEN 'FAIL - {{ validate_column }} mismatch (src: '
                     || COALESCE(e.{{ validate_column }}::VARCHAR, 'NULL')
                     || ', tgt: '
                     || COALESCE(t.{{ validate_column }}::VARCHAR, 'NULL') || ')'
            {% endif %}
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
-- Validates flags, effective_from and optional column.
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

        {% if validate_column is not none %}
        e.{{ validate_column }}                                          AS src_{{ validate_column }},
        t.{{ validate_column }}                                          AS tgt_{{ validate_column }},
        {% endif %}

        CASE
            WHEN t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Row missing in target for record_order '
                     || e.record_order::VARCHAR
            WHEN t.dwh_is_deleted_flag IS DISTINCT FROM 'Y'
                THEN 'FAIL - dwh_is_deleted_flag is not Y (actual: '
                     || COALESCE(t.dwh_is_deleted_flag, 'NULL') || ')'
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL - dwh_latest_dml_type_code is not D (actual: '
                     || COALESCE(t.dwh_latest_dml_type_code, 'NULL') || ')'
            WHEN e.exp_effective_from <> t.dwh_effective_from_tstamp
                THEN 'FAIL - effective_from mismatch (exp: '
                     || e.exp_effective_from::VARCHAR
                     || ', act: ' || t.dwh_effective_from_tstamp::VARCHAR || ')'
            WHEN e.exp_effective_to <> t.dwh_effective_to_tstamp
                THEN 'FAIL - effective_to mismatch (exp: '
                     || e.exp_effective_to::VARCHAR
                     || ', act: ' || t.dwh_effective_to_tstamp::VARCHAR || ')'
            {% if validate_column is not none %}
            WHEN e.{{ validate_column }} IS DISTINCT FROM t.{{ validate_column }}
                THEN 'FAIL - {{ validate_column }} mismatch (src: '
                     || COALESCE(e.{{ validate_column }}::VARCHAR, 'NULL')
                     || ', tgt: '
                     || COALESCE(t.{{ validate_column }}::VARCHAR, 'NULL') || ')'
            {% endif %}
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
-- (column check not applicable here — prior row is being
--  validated for effective_to back-dating only)
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

        {# ── NULL placeholders to keep UNION ALL column count consistent ── #}
        {% if validate_column is not none %}
        NULL::VARCHAR                                                    AS src_{{ validate_column }},
        NULL::VARCHAR                                                    AS tgt_{{ validate_column }},
        {% endif %}

        CASE
            WHEN prev_t.{{ key_columns[0] }} IS NULL
                THEN 'FAIL - Prior target row not found for record_order '
                     || (e.record_order - 1)::VARCHAR
            WHEN prev_t.dwh_effective_to_tstamp IS DISTINCT FROM
                 TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)
                THEN 'FAIL - Prior row not back-dated (exp: '
                     || TIMESTAMPADD(MICROSECOND, -1, e.exp_effective_from)::VARCHAR
                     || ', act: ' || prev_t.dwh_effective_to_tstamp::VARCHAR || ')'
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

-- Return ONLY failing rows — dbt PASS = 0 rows returned
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

{{ log("=== Generated SCD2 CDC Validation SQL ===", info=True) }}
{{ log(generated_sql,                               info=True) }}
{{ log("=== End of Generated SQL ===",              info=True) }}

{% if execute %}
    {% set results    = run_query(generated_sql) %}
    {% set fail_count = results.rows | length %}

    {{ log("[SCD2 Landing→Raw] Total failing rows : " ~ fail_count, info=True) }}

    {% if fail_count > 0 %}
        {{ log("Connect with data team for refresh", info=True) }}
        {% if raise_error %}
            {{ exceptions.raise_compiler_error(
                "SCD2 CDC validation FAILED for " ~ target_relation
                ~ " — " ~ fail_count ~ " failing row(s) found in the last "
                ~ look_back ~ " day(s). Check dbt.log for details."
            ) }}
        {% else %}
            {{ log("Warning: validation failed but continuing (raise_error=False).", info=True) }}
        {% endif %}
    {% else %}
        {{ log("SCD2 CDC validation PASSED for " ~ target_relation
               ~ " (last " ~ look_back ~ " day(s))", info=True) }}
    {% endif %}
{% endif %}

{{ return(generated_sql) }}

{% endmacro %}


{# =================================================================
   USAGE EXAMPLE — WITHOUT column validation (original behaviour)
   Save as: macros/test_scd2_cdc_validation.sql
================================================================= #}

{#
{{ test_scd2_cdc_validation(
    model                      = 'raw___bis___bst_cust_reln',
    source_name                = 'landing__bis',
    table_name                 = 'BST_CUST_RELN',
    key_columns                = ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                  'RELATIONSHIP_CODE','CUSTOMER2_NO'],
    source_json_column         = 'RECORD_CONTENT',
    source_key_paths           = ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                  'RELATIONSHIP_CODE','CUSTOMER2_NO'],
    source_key_types           = ['VARCHAR','TRIM_VARCHAR',
                                  'TRIM_VARCHAR','VARCHAR'],
    source_time_path           = 'metadata:time',
    target_from_column         = 'dwh_effective_from_tstamp',
    target_to_column           = 'dwh_effective_to_tstamp',
    target_deleted_flag_column = 'dwh_is_deleted_flag',
    target_dml_type_column     = 'dwh_latest_dml_type_code',
    ingestion_type             = 'kafka',
    load_type                  = 'type2',
    afterState                 = 'afterState',
    beforeState                = 'beforeState',
    look_back                  = 25,
    lag_minutes                = 60,
    raise_error                = False
) }}
#}


{# =================================================================
   USAGE EXAMPLE — WITH column validation
   Checks RELATIONSHIP_STATUS matches between source JSON and target.

   -- Source JSON path  : afterState.RELATIONSHIP_STATUS
   -- Target column     : RELATIONSHIP_STATUS_CODE (different name)
   -- Type              : TRIM_VARCHAR
================================================================= #}

{#
{{ test_scd2_cdc_validation(
    model                      = 'raw___bis___bst_cust_reln',
    source_name                = 'landing__bis',
    table_name                 = 'BST_CUST_RELN',
    key_columns                = ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                  'RELATIONSHIP_CODE','CUSTOMER2_NO'],
    source_json_column         = 'RECORD_CONTENT',
    source_key_paths           = ['CUSTOMER1_NO','RELATIONSHIP_TYPE',
                                  'RELATIONSHIP_CODE','CUSTOMER2_NO'],
    source_key_types           = ['VARCHAR','TRIM_VARCHAR',
                                  'TRIM_VARCHAR','VARCHAR'],
    source_time_path           = 'metadata:time',
    target_from_column         = 'dwh_effective_from_tstamp',
    target_to_column           = 'dwh_effective_to_tstamp',
    target_deleted_flag_column = 'dwh_is_deleted_flag',
    target_dml_type_column     = 'dwh_latest_dml_type_code',
    ingestion_type             = 'kafka',
    load_type                  = 'type2',
    afterState                 = 'afterState',
    beforeState                = 'beforeState',
    look_back                  = 25,
    lag_minutes                = 60,
    raise_error                = False,

    -- Non-key column validation (optional — omit to skip)
    validate_column            = 'RELATIONSHIP_STATUS',
    validate_column_path       = 'RELATIONSHIP_STATUS',
    validate_column_type       = 'TRIM_VARCHAR',
    target_validate_column     = 'RELATIONSHIP_STATUS_CODE'
) }}
#}


{# =================================================================
   USAGE EXAMPLE — Airflow DbtRunOperationOperator
   WITHOUT column validation  (mirrors kafka macro DAG pattern)
================================================================= #}

{#
scd2_validation_check = DbtRunOperationOperator(
    task_id="run_scd2_cdc_validation",
    macro_name="test_scd2_cdc_validation",
    project_dir=project_path,
    profile_config=profile_config,
    args={
        "model":                      "raw___bis___bst_cust_reln",
        "source_name":                "landing__bis",
        "table_name":                 "BST_CUST_RELN",
        "key_columns":                ["CUSTOMER1_NO", "RELATIONSHIP_TYPE",
                                       "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
        "source_json_column":         "RECORD_CONTENT",
        "source_key_paths":           ["CUSTOMER1_NO", "RELATIONSHIP_TYPE",
                                       "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
        "source_key_types":           ["VARCHAR", "TRIM_VARCHAR",
                                       "TRIM_VARCHAR", "VARCHAR"],
        "source_time_path":           "metadata:time",
        "target_from_column":         "dwh_effective_from_tstamp",
        "target_to_column":           "dwh_effective_to_tstamp",
        "target_deleted_flag_column": "dwh_is_deleted_flag",
        "target_dml_type_column":     "dwh_latest_dml_type_code",
        "ingestion_type":             "kafka",
        "load_type":                  "type2",
        "look_back":                  look_back,
        "raise_error":                "True"
    },
    dbt_executable_path=dbt_executable_path,
)
#}


{# =================================================================
   USAGE EXAMPLE — Airflow DbtRunOperationOperator
   WITH column validation
================================================================= #}

{#
scd2_validation_check = DbtRunOperationOperator(
    task_id="run_scd2_cdc_validation",
    macro_name="test_scd2_cdc_validation",
    project_dir=project_path,
    profile_config=profile_config,
    args={
        "model":                      "raw___bis___bst_cust_reln",
        "source_name":                "landing__bis",
        "table_name":                 "BST_CUST_RELN",
        "key_columns":                ["CUSTOMER1_NO", "RELATIONSHIP_TYPE",
                                       "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
        "source_json_column":         "RECORD_CONTENT",
        "source_key_paths":           ["CUSTOMER1_NO", "RELATIONSHIP_TYPE",
                                       "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
        "source_key_types":           ["VARCHAR", "TRIM_VARCHAR",
                                       "TRIM_VARCHAR", "VARCHAR"],
        "source_time_path":           "metadata:time",
        "target_from_column":         "dwh_effective_from_tstamp",
        "target_to_column":           "dwh_effective_to_tstamp",
        "target_deleted_flag_column": "dwh_is_deleted_flag",
        "target_dml_type_column":     "dwh_latest_dml_type_code",
        "ingestion_type":             "kafka",
        "load_type":                  "type2",
        "look_back":                  look_back,
        "raise_error":                "True",
        "validate_column":            "RELATIONSHIP_STATUS",
        "validate_column_path":       "RELATIONSHIP_STATUS",
        "validate_column_type":       "TRIM_VARCHAR",
        "target_validate_column":     "RELATIONSHIP_STATUS_CODE"
    },
    dbt_executable_path=dbt_executable_path,
)
#}
