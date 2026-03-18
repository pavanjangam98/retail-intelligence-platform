{% macro apply_tags() %}
    {% set out_str = 'ALTER TABLE ' ~ this ~ ' MODIFY\n' %}
    {% set this_db_name = this.database | upper %}
    {% set this_schema_name = this.schema | upper %}
    {% set this_table_name = this.identifier | upper %}
    {% set src_classification_table = source('classification','CLASSIFICATION_DATA_LV') | upper %}
    {% set src_tagging_schema = source('tags','TAGS').database ~ "." ~ source('tags','TAGS').schema | upper %}
    {% set bdh_isairflow = env_var('IS_AIRFLOW') %}
    {% set bdh_zone = var('DBT_BDH_ZONE') %}
    {% set info_columns = this_db_name + '.information_schema.columns' %}

    {# get the classification table details to get the tags from if applying to transform db #}
    {% if bdh_isairflow.lower() == "false" and this_db_name|length > 0 and this_table_name.split('___')|length > 2 %}
        {% set tgt_db_name = bdh_zone + '__' + this_table_name.split('___')[0] %}
        {% set tgt_schema_name = this_table_name.split('___')[1] %}
        {% set tgt_table_name = this_table_name.split('___')[2] %}
    {% elif this_db_name|length > 0 and this_db_name.split('__')|length > 1 %}
        {% set tgt_db_name = bdh_zone + '__' + this_db_name.split('__')[1] %}
        {% set tgt_schema_name = this_schema_name %}
        {% set tgt_table_name = this_table_name %}
    {% endif %}

    {# ------------------------------------------------------------------ #}
    {# FIX 1: initialise mod_strs OUTSIDE {% if execute %} so it is       #}
    {# always defined, preventing UndefinedError during compile/parse      #}
    {# ------------------------------------------------------------------ #}
    {% set mod_strs = [] %}

    {# ------------------------------------------------------------------ #}
    {# query the governance table for tags to apply                        #}
    {# Columns selected:                                                   #}
    {#   - COLUMN_NAME            : join/filter key (not a tag)            #}
    {#   - SECURITY_CLASSIFICATION_CODE  : governance tag                  #}
    {#   - IS_BUSINESS_KEY               : governance tag                  #}
    {#   - IS_PRIMARY_KEY                : governance tag                  #}
    {# Excluded (operational/SCD pipeline metadata, not governance tags):  #}
    {#   CLASSIFICATION_ID, DB_NAME, SCHEMA_NAME, TABLE_NAME,              #}
    {#   IS_SRC_DELETED, SOURCE_DS_UPDATED, WH_EFFECTIVE_FROM_TSTAMP,      #}
    {#   WH_EFFECTIVE_TO_TSTAMP, DBT_SCD_ID, WH_CHANGE_TYPE, IS_ACTIVE,   #}
    {#   WH_ATTRIBUTE_HASH, WH_PROCESS_TSTAMP                              #}
    {# ------------------------------------------------------------------ #}
    {% set query %}
        SELECT
            UPPER(trim(C.column_name))              AS column_name
            ,security_classification_code
            ,is_business_key
            ,is_primary_key
        FROM
            {{ src_classification_table }} C
        LEFT JOIN
            {{ info_columns }} I
        ON  UPPER(trim(C.column_name)) = UPPER(I.column_name)
            AND UPPER('{{ this_table_name }}') = UPPER(I.table_name)
            AND UPPER('{{ this_schema_name }}') = UPPER(I.table_schema)
        WHERE
            UPPER(trim(C.table_name))  = UPPER('{{ tgt_table_name }}')
            AND UPPER(trim(C.schema_name)) = UPPER('{{ tgt_schema_name }}')
            AND UPPER(trim(C.db_name))     = UPPER('{{ tgt_db_name }}')
            AND I.column_name IS NOT NULL
    {% endset %}

    {% set src_classification = run_query(query) %}

    {% if src_classification|length == 0 %}
        {# No rows in classification source → emit nothing, no ALTER TABLE #}
        {{ '' }}
    {% else %}
        {% if execute %}

            {# ---------------------------------------------------------- #}
            {# FIX 2: fetch currently applied tag values from              #}
            {# TAG_REFERENCES so we can diff and only ALTER changed cols   #}
            {# ---------------------------------------------------------- #}
            {% set existing_tags_query %}
                SELECT
                    UPPER(COLUMN_NAME)   AS column_name
                    ,UPPER(TAG_NAME)     AS tag_name
                    ,TAG_VALUE           AS current_value
                FROM
                    TABLE({{ this_db_name }}.information_schema.tag_references(
                        '{{ this_db_name }}.{{ this_schema_name }}.{{ this_table_name }}',
                        'table'
                    ))
                WHERE
                    DOMAIN = 'COLUMN'
            {% endset %}

            {% set existing_tags_result = run_query(existing_tags_query) %}

            {# Build a lookup dict:  (COLUMN_NAME, TAG_NAME) → current_value #}
            {% set existing_tag_map = {} %}
            {% if existing_tags_result|length > 0 %}
                {% for row in existing_tags_result.rows %}
                    {% set lookup_key = row[0] ~ '||' ~ row[1] %}
                    {% do existing_tag_map.update({ lookup_key: row[2] }) %}
                {% endfor %}
            {% endif %}

            {# ---------------------------------------------------------- #}
            {# Generate MODIFY clauses only for tags whose value has       #}
            {# changed (or that have never been applied before)            #}
            {# ---------------------------------------------------------- #}
            {% set classification_list = src_classification.rows %}
            {% set column_list        = src_classification.column_names %}

            {% for classification in classification_list %}
                {% set col_name  = classification[0] | upper %}
                {% set col_str   = [] %}
                {% set tag_strs  = [] %}
                {% set has_change = [] %}   {# used as a boolean flag #}

                {% for i in range(column_list|length) %}
                    {% if column_list[i] == "COLUMN_NAME" %}
                        {% do col_str.append(' COLUMN ' ~ classification[i] ~ ' SET TAG ') %}
                    {% else %}
                        {# Derive the full tag name as it appears in TAG_REFERENCES #}
                        {% set full_tag_name = (src_tagging_schema ~ '.' ~ column_list[i]) | upper %}
                        {% set new_value     = classification[i] | string %}
                        {% set lookup_key    = col_name ~ '||' ~ full_tag_name %}
                        {% set current_value = existing_tag_map.get(lookup_key, '__NOT_SET__') %}

                        {# Always include if not yet set; include if value differs #}
                        {% if current_value != new_value %}
                            {% do has_change.append(1) %}
                        {% endif %}

                        {% do tag_strs.append(' ' ~ src_tagging_schema ~ '.' ~ column_list[i] ~ ' = "' ~ new_value ~ '"') %}
                    {% endif %}
                {% endfor %}

                {# Only append a modify clause if at least one tag changed #}
                {% if has_change | length > 0 %}
                    {% do mod_strs.append(col_str | join(', ') + tag_strs | join(', ')) %}
                {% endif %}
            {% endfor %}

        {% endif %} {# end execute #}

        {# Emit ALTER only when there is at least one changed column #}
        {% if mod_strs | length > 0 %}
            {{ out_str + mod_strs | join('\n ,') }}
        {% endif %}

    {% endif %}
{% endmacro %}
