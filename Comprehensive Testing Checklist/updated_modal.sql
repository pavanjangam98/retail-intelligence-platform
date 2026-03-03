{{ config(
    materialized = 'incremental',
    unique_key   = ['db_name','schema_name','table_name','column_name'],
    on_schema_change = 'sync_all_columns'
) }}

WITH temp_table AS (

    SELECT 
        am_base.object_id,
        am_base.object_type,
        am_base.catalog_set_ids,
        cm.catalog_set_property_id      AS cm_set_id,
        cm.catalog_set_title,
        rc.column_id,
        rc.name                         AS column_name,
        rc.title                        AS column_title,
        rc.table_id,
        rt.name                         AS table_name,
        rc.schema_id,
        split_part(rs.name, '.', 2)     AS schema_name,
        rs.db_catalog_name              AS db_name,
        rc.is_primary_key,
        rc.data_type,
        cm.business_key,
        cm.security_classification,
        array_to_string(cm.classification_tag, ',') AS classification_tag_str,
        cm.ts_updated

    FROM {{ source('alation_analytics_share', 'alation_set_member') }} am_base

    CROSS JOIN LATERAL FLATTEN(input => am_base.catalog_set_ids) f

    JOIN {{ source('alation_analytics_share', 'catalog_set_membership') }} cm
        ON f.value::string = cm.catalog_set_property_id

    JOIN {{ source('alation_analytics_share', 'rdbms_columns') }} rc
        ON am_base.object_id = rc.column_id

    JOIN {{ source('alation_analytics_share', 'rdbms_tables') }} rt
        ON rc.table_id = rt.table_id

    JOIN {{ source('alation_analytics_share', 'rdbms_schemas') }} rs
        ON rt.schema_id = rs.schema_id

    WHERE am_base.object_type = 'attribute'
      AND cm.deleted = FALSE
      AND rt.ds_id = 27
      AND UPPER(rs.db_catalog_name) = 'LOANS__RAW__DEV'

    {% if is_incremental() %}
        AND cm.ts_updated > (
            SELECT COALESCE(MAX(last_updated), '1900-01-01'::timestamp)
            FROM {{ this }}
        )
    {% endif %}

),

/* STEP 1: Sensitivity Ranking */
cleaned AS (

    SELECT
        db_name,
        schema_name,
        table_name,
        column_name,

        COALESCE(
            REGEXP_REPLACE(security_classification, '[\\{\\}''"]', ''),
            'Unclassified'
        ) AS security_classification_code,

        classification_tag_str,
        business_key,
        is_primary_key,
        data_type,
        catalog_set_title,
        ts_updated,
        security_classification,

        CASE 
            WHEN UPPER(security_classification) IN ('HIGHLY CONFIDENTIAL','UNCLASSIFIED') THEN 1
            WHEN UPPER(security_classification) = 'CONFIDENTIAL' THEN 2
            WHEN UPPER(security_classification) = 'PRIVATE' THEN 3
            WHEN UPPER(security_classification) = 'PUBLIC' THEN 4
            ELSE 5
        END AS sensitivity_rank

    FROM temp_table
),

/* STEP 2: Detect Upgrade/Downgrade */
classified AS (

    SELECT *,
        LAG(sensitivity_rank) OVER (
            PARTITION BY db_name, schema_name, table_name, column_name
            ORDER BY ts_updated
        ) AS prev_rank
    FROM cleaned
),

/* STEP 3: Smart Ranking */
ranked AS (

    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY db_name, schema_name, table_name, column_name
            ORDER BY 

                /* Upgrade → prefer more sensitive */
                CASE 
                    WHEN prev_rank IS NOT NULL 
                         AND sensitivity_rank < prev_rank
                    THEN sensitivity_rank
                END ASC,

                /* Downgrade → prefer latest */
                CASE 
                    WHEN prev_rank IS NOT NULL 
                         AND sensitivity_rank > prev_rank
                    THEN ts_updated
                END DESC,

                /* Fallback → latest always wins */
                ts_updated DESC

        ) AS rn
    FROM classified
)

SELECT
    db_name,
    schema_name,
    table_name,
    column_name,
    security_classification_code,
    COALESCE(REGEXP_REPLACE(business_key, '[\\{\\}''"]', ''), 'FALSE') AS is_business_key,
    COALESCE(is_primary_key, FALSE) AS is_primary_key,
    data_type,
    catalog_set_title,
    ts_updated AS last_updated,
    CURRENT_TIMESTAMP AS record_created_at,
    CURRENT_TIMESTAMP AS record_updated_at

FROM ranked
WHERE rn = 1
