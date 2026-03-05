{% macro generate_alias_name(custom_alias_name=none, node=none) %}
    {# Split the node name into components #}
     -- Assign the  target environment
    {% set environment = target.name.lower() %}
    {# assign the zone dbtvariable  #}
     -- It pulls the IS_AIRFLOW  environment variable
    {% set bdh_isairflow = env_var('IS_AIRFLOW')  %}
     -- The macro takes the node.name and splits it into parts based on the delimiter __ (expecting a three-part structure: database, schema, and object).
    {% set node_name = node.name  %}
    {% set split_name = node_name.split('___', 2) %}
    {% set node_type = node.unique_id.split('.', 1)[0] %}
    {% set bdh_package = 'bdh' in node.unique_id.split('.', 2)[1] %}

    -- NEW: Detect whether the node name is 2-part (database___object) or 3-part (database___schema___object)
    {% set is_three_part = split_name | length == 3 %}
    {% set is_two_part   = split_name | length == 2 %}

    -- CHANGED: object_name now resolves based on split length
    -- 3-part (database___schema___object): object = split_name[2]
    -- 2-part (database___object):          object = split_name[1]
    {% if is_three_part %}
        {% set object_name = split_name[2] %}
    {% elif is_two_part %}
        {% set object_name = split_name[1] %}
    {% else %}
        {% set object_name = none %}
    {% endif %}

     -- Error Handling for Invalid Naming or Configurations:    
     -- The macro checks that the node name has three parts when the node is of type model, snapshot, or seed and is part of the bdh package.    
    {# Validate the split resulted in three parts, otherwise raise an error #}
    -- CHANGED: relaxed from != 3 to < 2 to allow both 2-part and 3-part naming conventions
    {% if bdh_package and node_type in ['model', 'snapshot', 'seed'] and split_name | length < 2 %}
        {{ exceptions.raise_compiler_error('Invalid naming syntax (should be <database>___<schema>___<object> or <database>___<object>): ' ~ node_name) }}
    {% endif %}
 
    {# Validate the environment #}
     -- It ensures the environment is valid (dev, tst, or prd).
    {% if environment not in ['dev', 'syst', 'ppte','prod'] %}
        {{ exceptions.raise_compiler_error('Unsupported target defined (should be dev, tst, or prd): ' ~ environment) }}
    {% endif %}
     --Generate Alias Name Based on Node Version and Environment:
    {# Generate the final alias name based on node version and environment #}
    {# Checking for is excution mode is an airflow #}
      --If the environment is dev and isairflow or the node type is operation,it generates the alias name based on the full node name
    {% if environment == 'dev' and bdh_isairflow == "false"  or node_type == 'operation' or not bdh_package %}
 
        {% if node_name is none %}
            {{ exceptions.raise_compiler_error('Invalid node ID for generating node name in alias generation: ' ~ node.unique_id) }}
        {% endif %}
        --If the node has a version (via node.version), the version is appended to the node name, with dots replaced by underscores (_vX_X format).
        {% if node.version %}
            {# Append a version suffix if the node has a version #}
            {{ return(node_name ~ '_v' ~ node.version | replace('.', '_')) }}
        {% else %}
            {# Use full name if in the developer schema #}
            --If no version exists, the full node name is used as the alias.
            {{ return(node_name) }}
        {% endif %}
    {% else %}
 
        {% if object_name is none %}
            {{ exceptions.raise_compiler_error('Invalid node ID for generating object name in alias generation: ' ~ node.unique_id) }}
        {% endif %}
 
        {% if node.version %}
            {# Append a version suffix if the node has a version #}
            {{ log("generate_alias_name:version: {0}".format(object_name ~ '_v' ~ node.version | replace('.', '_'))) }}
            {{ return(object_name ~ '_v' ~ node.version | replace('.', '_')) }}
        {% else %}
            {# Use the short alias if in production or testing #}
            --In production or testing environments, the alias name is based on the object name extracted from the node.
            {{ return(object_name) }}
        {% endif %}

  ++++++++++++++++++++++++

  {% macro generate_database_name(custom_database_name=none, node=none) %}
 
    {# Split the node name into database, schema, and object name components #}
    {# assign the zone dbtvariable  #}
    -- It pulls the DBT_BDH_ZONE  dbt variable
    {% set bdh_zone = var('DBT_BDH_ZONE') %}
    {# assign the is_airflow environment variable and assign default value as false #}
    -- It pulls the IS_AIRFLOW  environment variable
    {% set bdh_isairflow = env_var('IS_AIRFLOW') %}
    -- Assign the current target environment ,the node name, and splits the node name to identify parts like database ,schema ,object
    {% set environment = target.name.lower() %}
    {% set node_name = node.name %}
    {% set split_name = node_name.split('___', 2) %}
    {% set node_type = node.unique_id.split('.', 1)[0] %}
    {% set bdh_package = 'bdh' in node.unique_id.split('.', 2)[1] %}
    {% set database_name = split_name[0] %}

    -- NEW: Detect whether the node name is 2-part (database___object) or 3-part (database___schema___object)
    {% set is_three_part = split_name | length == 3 %}
    {% set is_two_part   = split_name | length == 2 %}

    -- Error handling for invalid naming or configurations:
    -- If the node type is one of model, snapshot, or seed, but the node name doesn't follow the expected database__schema__object format, it raises an error.
    {# Validate the split resulted in three parts, otherwise raise an error #}
    -- CHANGED: relaxed from != 3 to < 2 to allow both 2-part and 3-part naming conventions
    {% if bdh_package and node_type in ['model', 'snapshot', 'seed'] and split_name | length < 2 %}
        {{ exceptions.raise_compiler_error('Invalid naming syntax (should be <database>___<schema>___<object> or <database>___<object>): ' ~ node_name) }}
    {% endif %}
 
    {# Validate the environment #}
    -- It also checks if the environment is valid (dev, tst, or prd), and raises an error if not.
    {% if environment not in ['dev', 'syst', 'ppte','prod'] %}
        {{ exceptions.raise_compiler_error('Unsupported target defined (should be dev, tst, or prd): ' ~ environment) }}
    {% endif %}
    --It ensures that the target.database is defined before proceeding.
    {% if target.database is none %}
        {{ exceptions.raise_compiler_error('Invalid node ID for generating database name in database generation: ' ~ node.unique_id) }}
    {% endif %}
    {# Generate the final database name based on environment conditions #}
    {# Checking for is excution mode is an airflow #}
    -- Check isairflow environment
    {%- if bdh_isairflow == "false" -%}
        -- If the environment is dev or the node type is operation, it directly returns the target.database.
        {% if environment == 'dev' or node_type == 'operation' %}
            {{ return(target.database.lower()) }}
        {% elif not bdh_package %}
            {{ return((bdh_zone ~ '__Transform'  ~ environment) if custom_database_name is none else custom_database_name) }}
        {% else %}
            {% if database_name is none %}
                {{ exceptions.raise_compiler_error('Invalid node ID for generating database name in database generation: ' ~ node.unique_id) }}
            {% endif %}
            -- generating database names dynamically, ensuring that naming conventions and environments are properly handled.
            -- NOTE: database_name is always split_name[0] so this works identically for both 2-part and 3-part
            {{ return((bdh_zone ~ '__' ~ database_name ~ '__' ~ environment) if custom_database_name is none else custom_database_name) }}
        {% endif %}
 
    {%- else -%}
       
        {% if database_name is none %}
            {{ exceptions.raise_compiler_error('Invalid node ID for generating database name in database generation: ' ~ node.unique_id) }}
        {% endif %}
        -- generating database names dynamically, ensuring that naming conventions and environments are properly handled.
        -- NOTE: database_name is always split_name[0] so this works identically for both 2-part and 3-part
        {{ return((bdh_zone ~ '__' ~ database_name ~ '__' ~ environment) if custom_database_name is none else custom_database_name) }}  
    {%- endif -%}      
{% endmacro %}

  +++++++++++++++++++++++++++++++++
{% macro generate_schema_name(custom_schema_name=none, node=none) %}
    {# Split the node name into components #}
     -- Assign the  target environment
    {% set environment = target.name.lower() %}
    {# Assgin the is_airflow environment variable and assign default value as false #}
     -- It pulls the IS_AIRFLOW  environment variable
    {% set bdh_isairflow = env_var('IS_AIRFLOW') %}
     -- Assign the current target environment ,the node name, and splits the node name to identify parts like database ,schema ,object
    {% set node_name = node.name %}
    {% set split_name = node_name.split('___', 2) %}
    {% set node_type = node.unique_id.split('.', 1)[0] %}
    {% set bdh_package = 'bdh' in node.unique_id.split('.', 2)[1] %}

    -- NEW: Detect whether the node name is 2-part (database___object) or 3-part (database___schema___object)
    {% set is_three_part = split_name | length == 3 %}
    {% set is_two_part   = split_name | length == 2 %}

    -- NEW: schema_name resolves to split_name[1] for 3-part, or none for 2-part (no schema encoded in name)
    {% set schema_name = split_name[1] if is_three_part else none %}

    -- Error handling for invalid naming or configurations:
    -- If the node type is one of model, snapshot, or seed, but the node name doesn't follow the expected database__schema__object format, it raises an error.
    {# Validate the split resulted in three parts, otherwise raise an error #}
    -- CHANGED: relaxed from != 3 to < 2 to allow both 2-part and 3-part naming conventions
    {% if bdh_package and node_type in ['model', 'snapshot', 'seed'] and split_name | length < 2 %}
        {{ exceptions.raise_compiler_error('Invalid naming syntax (should be <database>___<schema>___<object> or <database>___<object>): ' ~ node_name) }}
    {% endif %}
 
    {# Validate the environment #}
    -- It also checks if the environment is valid (dev, tst, or prd), and raises an error if not.
    {% if environment not in ['dev', 'syst', 'ppte','prod'] %}
        {{ exceptions.raise_compiler_error('Unsupported target defined (should be dev, tst, or prd): ' ~ environment) }}
    {% endif %}
    --It ensures that the target.database is defined before proceeding.
    {% if target.schema is none %}
        {{ exceptions.raise_compiler_error('Invalid node ID for generating schema name in schema generation: ' ~ node.unique_id) }}
    {% endif %}
    -- It also checks that the target.schema is defined, raising an error if it's not.
    {# Generate schema name depending on if the node is a part of an external package #}
    {% set schema_name = target.schema.lower() if custom_schema_name is none else custom_schema_name %}
 
    --Node Type and Package Handling:
    {% if bdh_package %}
        -- CHANGED: for 3-part use split_name[1] as schema; for 2-part fall back to target.schema (no schema in name)
        {% if is_three_part %}
            {% set schema_name = split_name[1] if custom_schema_name is none else custom_schema_name %}
        {% elif is_two_part %}
            {% set schema_name = target.schema.lower() if custom_schema_name is none else custom_schema_name %}
        {% endif %}
    {% endif %}
   
   -- Final Schema Name Generation:
    {# Generate the final schema name based on environment conditions #}
    {# Checking for is excution mode is an airflow #}
    --  Check isairflow environment
    {%- if bdh_isairflow == "false" -%}
        -- If the environment is dev or node type is operation, it returns the schema as defined by target.schema.
        {% if environment == 'dev'  or node_type == 'operation' %}
            {{ return(target.schema.lower()) }}
        {% elif environment == 'syst' %}
            {% if schema_name is none %}
                {{ exceptions.raise_compiler_error('Invalid node ID for generating schema name in schema generation: ' ~ node.unique_id) }}
            {% endif %}    
            {{ return(schema_name | trim) }}
        {% else %}
            {% if schema_name is none %}
                {{ exceptions.raise_compiler_error('Invalid node ID for generating schema name in schema generation: ' ~ node.unique_id) }}
            {% endif %}
            {{ return(schema_name | trim) }}
        {% endif %}
    {%- else -%}
        {% if schema_name is none %}
            {{ exceptions.raise_compiler_error('Invalid node ID for generating schema name in schema generation: ' ~ node.unique_id) }}
        {% endif %}
        -- In tst,prd, it returns the schema name without modification.
        {{ return(schema_name | trim) }}
    {%- endif -%}      
{% endmacro %}

    {% endif %}
{% endmacro %}
