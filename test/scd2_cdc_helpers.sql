{# ================================================================
   Helper macros for test_scd2_cdc_validation.
   Must be in a separate file — Jinja does not allow macro
   definitions nested inside another macro.
================================================================ #}

{# Extracts and casts a key column from JSON (afterState/beforeState) #}
{% macro extract_key(source_json_column, afterState, beforeState, path, key_type) %}
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


{# Renders target SELECT for one key — TRIM_VARCHAR gets TRIM() #}
{% macro target_key(col, key_type) %}
    {% if key_type == 'TRIM_VARCHAR' %}
        TRIM({{ col }}) AS {{ col }}
    {% else %}
        {{ col }}
    {% endif %}
{% endmacro %}


{# Renders PARTITION BY entry — TRIM_VARCHAR needs explicit TRIM()
   because window functions cannot reference aliases in same SELECT #}
{% macro target_partition_key(col, key_type) %}
    {% if key_type == 'TRIM_VARCHAR' %}
        TRIM({{ col }})
    {% else %}
        {{ col }}
    {% endif %}
{% endmacro %}
