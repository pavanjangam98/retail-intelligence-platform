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
    raise_error=False
) %}

{# =================================================================
   Macro : test_scd2_cdc_validation
   Validates SCD Type-2 CDC pipeline from LANDING to RAW layer.
   Single file — no helper macros needed.
   Helper logic inlined using Jinja if/elif inside for loops.
   Supports : INSERT / UPDATE / DELETE / LATE ARRIVAL scenarios.

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
   ingestion_type             : ingestion pattern (default 'kafka')
   load_type                  : load strategy, controls time column
                                'type2'  → DWH_EFFECTIVE_FROM_TSTAMP
                                'append' → DWH_EXTRACTION_TSTAMP
                                (default 'type2')
   afterState                 : JSON key for after-image
                                (default 'afterState')
   beforeState                : JSON key for before-image
                                (default 'beforeState')
   look_back                  : days to look back (default 25)
   lag_minutes                : lag in minutes to skip recent
                                unprocessed data (default 60)
   raise_error                : raise compiler error on failure
                                (default False)
================================================================= #}

{# ── Resolve relations from model name and source/table strings ── #}
{% set target_relation = ref(model) %}
{% set source_relation = source(source_name, table_name) %}

{{ log("=== SCD2 CDC Validation (Landing → Raw) Started ===",     info=True) }}
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
        {# ── Key columns: JSON extraction inlined (no helper macro needed) ──
           NUMBER       → IFF(...)::NUMBER
           VARCHAR      → TRIM(IFF(...)::VARCHAR, '"')
           TRIM_VARCHAR → TRIM(TRIM(IFF(...)::VARCHAR, '"'))        #}
        {% for i in range(key_columns | length) %}
            {% set col  = key_columns[i] %}
            {% set path = source_key_paths[i] %}
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

        {# Late arrival: event arrived after a later event was already processed #}
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
        {# ── Target key columns cast to match source extraction type ──
           VARCHAR      → {{ col }}::VARCHAR  (ensures JOIN matches)
           TRIM_VARCHAR → TRIM({{ col }}::VARCHAR) (trim + cast)
           NUMBER       → {{ col }} as-is (numeric join)            #}
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

        {{ target_from_column }}                                         AS dwh_effective_from_tstamp,
        {{ target_to_column }}                                           AS dwh_effective_to_tstamp,
        {{ target_dml_type_column }}                                     AS dwh_latest_dml_type_code,
        {{ target_deleted_flag_column }}                                 AS dwh_is_deleted_flag,

        ROW_NUMBER() OVER (
            PARTITION BY
                {# Must use same expression as SELECT — aliases not
                   resolvable inside window functions in Snowflake  #}
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
                THEN 'FAIL'   -- deleted flag not Y
            WHEN t.dwh_latest_dml_type_code IS DISTINCT FROM 'D'
                THEN 'FAIL'   -- DML type not D
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
                THEN 'FAIL'   -- prior target row not found
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
   USAGE EXAMPLE — dbt test file
   Save as: tests/scd2_bst_cust_reln.sql
================================================================= #}

{#
{{ test_scd2_cdc_validation(
    model                      = 'raw___bis___bst_cust_reln',
    source_name                = 'landing__bis',
    table_name                 = 'BST_CUST_RELN',

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
                                    'VARCHAR',       -- CUSTOMER1_NO      → TRIM(::VARCHAR,'"')
                                    'TRIM_VARCHAR',  -- RELATIONSHIP_TYPE  → TRIM(TRIM(::VARCHAR,'"'))
                                    'TRIM_VARCHAR',  -- RELATIONSHIP_CODE  → TRIM(TRIM(::VARCHAR,'"'))
                                    'VARCHAR'        -- CUSTOMER2_NO       → TRIM(::VARCHAR,'"')
                                 ],

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
   USAGE EXAMPLE — Airflow DbtRunOperationOperator
   (mirrors the kafka macro DAG pattern exactly)
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
