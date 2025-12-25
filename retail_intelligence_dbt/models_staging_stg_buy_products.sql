{{
  config(
    materialized='view',
    schema='staging'
  )
}}

WITH source AS (
  SELECT * FROM {{ source('raw', 'BUY_PRODUCTS') }}
),

cleaned AS (
  SELECT
    ID as product_id,
    TRIM(UPPER(NAME)) as product_name,
    TRIM(DESCRIPTION) as description,
    TRIM(UPPER(MANUFACTURER)) as manufacturer,
    TRY_CAST(
      REPLACE(REPLACE(REPLACE(PRICE, '$', ''), ',', ''), ' ', '') 
      AS DECIMAL(10,2)
    ) as price_numeric,
    PRICE as price_raw,
    'BUY' as source_retailer,
    ARRAY_AGG(DISTINCT value) WITHIN GROUP (ORDER BY value) as name_tokens,
    LOADED_AT as loaded_timestamp
  FROM source,
    LATERAL FLATTEN(
      input => SPLIT(UPPER(TRIM(NAME)), ' ')
    )
  WHERE NAME IS NOT NULL AND TRIM(NAME) != ''
  GROUP BY ID, NAME, DESCRIPTION, MANUFACTURER, PRICE, LOADED_AT
)

SELECT * FROM cleaned