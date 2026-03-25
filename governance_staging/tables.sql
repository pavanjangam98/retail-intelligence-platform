{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='table_id',
    on_schema_change='sync_all_columns'
) }}

WITH source_data AS (
    SELECT
        *,
        CURRENT_TIMESTAMP AS LOADED_AT
    FROM {{ source('alation_share', 'rdbms_tables') }}
    WHERE DS_ID IN (19,27)
),

incremental_filter AS (
    SELECT *
    FROM source_data
    {% if is_incremental() %}
    WHERE GREATEST(
        COALESCE(TS_UPDATED, '1900-01-01'),
        COALESCE(TS_DELETED, '1900-01-01')
    ) >
    (
        SELECT COALESCE(
            DATEADD(day, -1,
                MAX(
                    GREATEST(
                        COALESCE(TS_UPDATED, '1900-01-01'),
                        COALESCE(TS_DELETED, '1900-01-01')
                    )
                )
            ),
            '1900-01-01'
        )
        FROM {{ this }}
    )
    {% endif %}
)

SELECT *
FROM incremental_filter

++++++++++++++++++

{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='column_id',
    on_schema_change='sync_all_columns'
) }}

WITH source_data AS (
    SELECT
        *,
        CURRENT_TIMESTAMP AS LOADED_AT
    FROM {{ source('alation_share', 'rdbms_columns') }}
    WHERE DS_ID IN (19,27)
),

incremental_filter AS (
    SELECT *
    FROM source_data
    {% if is_incremental() %}
    WHERE GREATEST(
        COALESCE(TS_UPDATED, '1900-01-01'),
        COALESCE(TS_DELETED, '1900-01-01')
    ) >
    (
        SELECT COALESCE(
            DATEADD(day, -1,
                MAX(
                    GREATEST(
                        COALESCE(TS_UPDATED, '1900-01-01'),
                        COALESCE(TS_DELETED, '1900-01-01')
                    )
                )
            ),
            '1900-01-01'
        )
        FROM {{ this }}
    )
    {% endif %}
)

SELECT *
FROM incremental_filter

++++++++++++++++++++

{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='schema_id',
    on_schema_change='sync_all_columns'
) }}

WITH source_data AS (
    SELECT
        *,
        CURRENT_TIMESTAMP AS LOADED_AT
    FROM {{ source('alation_share', 'rdbms_schemas') }}
    WHERE DS_ID IN (19,27)
),

incremental_filter AS (
    SELECT *
    FROM source_data
    {% if is_incremental() %}
    WHERE GREATEST(
        COALESCE(TS_UPDATED, '1900-01-01'),
        COALESCE(TS_DELETED, '1900-01-01')
    ) >
    (
        SELECT COALESCE(
            DATEADD(day, -1,
                MAX(
                    GREATEST(
                        COALESCE(TS_UPDATED, '1900-01-01'),
                        COALESCE(TS_DELETED, '1900-01-01')
                    )
                )
            ),
            '1900-01-01'
        )
        FROM {{ this }}
    )
    {% endif %}
)

SELECT *
FROM incremental_filter

++++++++++++++++++++++++


{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='id',
    on_schema_change='sync_all_columns'
) }}

WITH source_data AS (
    SELECT
        *,
        CURRENT_TIMESTAMP AS LOADED_AT
    FROM {{ source('alation_share', 'alation_set_member') }}
),

incremental_filter AS (
    SELECT *
    FROM source_data
    {% if is_incremental() %}
    WHERE GREATEST(
        COALESCE(TS_UPDATED, '1900-01-01'),
        COALESCE(TS_DELETED, '1900-01-01')
    ) >
    (
        SELECT COALESCE(
            DATEADD(day, -1,
                MAX(
                    GREATEST(
                        COALESCE(TS_UPDATED, '1900-01-01'),
                        COALESCE(TS_DELETED, '1900-01-01')
                    )
                )
            ),
            '1900-01-01'
        )
        FROM {{ this }}
    )
    {% endif %}
)

SELECT *
FROM incremental_filter

+++++++++++++++++++++

{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='id',
    on_schema_change='sync_all_columns'
) }}

WITH source_data AS (
    SELECT
        *,
        CURRENT_TIMESTAMP AS LOADED_AT
    FROM {{ source('alation_share', 'rdbms_datasources') }}
    WHERE DS_ID IN (19, 27)
),

incremental_filter AS (
    SELECT *
    FROM source_data
    {% if is_incremental() %}
    WHERE GREATEST(
        COALESCE(TS_UPDATED, '1900-01-01'),
        COALESCE(TS_DELETED, '1900-01-01')
    ) >
    (
        SELECT COALESCE(
            DATEADD(day, -1,
                MAX(
                    GREATEST(
                        COALESCE(TS_UPDATED, '1900-01-01'),
                        COALESCE(TS_DELETED, '1900-01-01')
                    )
                )
            ),
            '1900-01-01'
        )
        FROM {{ this }}
    )
    {% endif %}
)

SELECT *
FROM incremental_filter
+++++++++++++++++++++++++++++++++++
