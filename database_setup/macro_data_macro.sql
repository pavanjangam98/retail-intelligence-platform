{% macro generate_database_name(custom_database_name=none, node=none) %}

    {# Split the node name into database, schema, and object name components #}
    {# assign the zone dbt variable #}
    {# -- It pulls the DBT_BDH_ZONE dbt variable #}
    {% set bdh_zone = var('DBT_BDH_ZONE') %}
    {# assign the is_airflow environment variable and assign default value as false #}
    {# -- It pulls the IS_AIRFLOW environment variable #}
    {% set bdh_isairflow = env_var('IS_AIRFLOW') %}
    {# -- Assign the current target environment ,the node name, and splits the node name to identify parts like database ,schema ,object #}
    {% set environment = target.name.lower() %}
    {% set node_name = node.name %}
    {% set split_name = node_name.split('___', 2) %}
    {% set node_type = node.unique_id.split('.', 1)[0] %}
    {% set bdh_package = 'bdh' in node.unique_id.split('.', 2)[1] %}
    {% set database_name = split_name[0] %}

    {# -- NEW: Detect whether the node name is 2-part (database___object) or 3-part (database___schema___object) #}
    {% set is_three_part = split_name | length == 3 %}
    {% set is_two_part   = split_name | length == 2 %}

    {# Error handling for invalid naming or configurations #}
    {# -- If the node type is one of model, snapshot, or seed, but the node name doesn't follow the expected format, it raises an error. #}
    {# Validate the split resulted in two or three parts, otherwise raise an error #}
    {# -- CHANGED: relaxed from != 3 to < 2 to allow both 2-part and 3-part naming conventions #}
    {% if bdh_package and node_type in ['model', 'snapshot', 'seed'] and split_name | length < 2 %}
        {{ exceptions.raise_compiler_error('Invalid naming syntax (should be <database>___<schema>___<object> or <database>___<object>): ' ~ node_name) }}
    {% endif %}

    {# Validate the environment #}
    {# -- It also checks if the environment is valid (dev, syst, ppte, or prod), and raises an error if not. #}
    {% if environment not in ['dev', 'syst', 'ppte', 'prod'] %}
        {{ exceptions.raise_compiler_error('Unsupported target defined (should be dev, tst, or prd): ' ~ environment) }}
    {% endif %}
    {# -- It ensures that the target.database is defined before proceeding. #}
    {% if target.database is none %}
        {{ exceptions.raise_compiler_error('Invalid node ID for generating database name in database generation: ' ~ node.unique_id) }}
    {% endif %}

    {# Generate the final database name based on environment conditions #}
    {# Checking for is execution mode is an airflow #}
    {% if bdh_isairflow == "false" %}
        {# -- Check isairflow environment #}
        {# -- If the environment is dev or the node type is operation, it directly returns the target.database. #}
        {% if environment == 'dev' or node_type == 'operation' %}
            {{ return(target.database.lower()) }}
        {% elif not bdh_package %}
            {{ return((bdh_zone ~ '__Transform' ~ environment) if custom_database_name is none else custom_database_name) }}
        {% else %}
            {% if database_name is none %}
                {{ exceptions.raise_compiler_error('Invalid node ID for generating database name in database generation: ' ~ node.unique_id) }}
            {% endif %}
            {# -- generating database names dynamically, ensuring that naming conventions and environments are properly handled. #}
            {# -- CHANGED: 2-part model (database___object) uses bdh_zone__environment only, avoiding doubling of zone and database segment #}
            {# -- 3-part model (database___schema___object) uses bdh_zone__database_name__environment as before #}
            {% if is_two_part %}
                {{ return((bdh_zone ~ '__' ~ environment) if custom_database_name is none else custom_database_name) }}
            {% else %}
                {{ return((bdh_zone ~ '__' ~ database_name ~ '__' ~ environment) if custom_database_name is none else custom_database_name) }}
            {% endif %}
        {% endif %}
    {% else %}
        {% if database_name is none %}
            {{ exceptions.raise_compiler_error('Invalid node ID for generating database name in database generation: ' ~ node.unique_id) }}
        {% endif %}
        {# -- generating database names dynamically, ensuring that naming conventions and environments are properly handled. #}
        {# -- CHANGED: 2-part model (database___object) uses bdh_zone__environment only, avoiding doubling of zone and database segment #}
        {# -- 3-part model (database___schema___object) uses bdh_zone__database_name__environment as before #}
        {% if is_two_part %}
            {{ return((bdh_zone ~ '__' ~ environment) if custom_database_name is none else custom_database_name) }}
        {% else %}
            {{ return((bdh_zone ~ '__' ~ database_name ~ '__' ~ environment) if custom_database_name is none else custom_database_name) }}
        {% endif %}
    {% endif %}
{% endmacro %}
