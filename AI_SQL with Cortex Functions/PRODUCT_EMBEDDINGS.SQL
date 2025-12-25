USE SCHEMA RETAIL_INTELLIGENCE_DB.ANALYTICS;

-- Create embeddings table
CREATE OR REPLACE TABLE PRODUCT_EMBEDDINGS AS
SELECT
  product_id,
  source_retailer,
  product_name,
  description,
  -- Generate embeddings using Cortex
  SNOWFLAKE.CORTEX.EMBED_TEXT_768(
    'e5-base-v2',
    CONCAT(
      product_name, 
      ' ', 
      COALESCE(description, '')
    )
  ) as product_embedding,
  CURRENT_TIMESTAMP() as embedding_created_at
FROM (
  SELECT 
    product_id,
    source_retailer,
    product_name,
    description
  FROM STAGING.STG_ABT_PRODUCTS
  
  UNION ALL
  
  SELECT 
    product_id,
    source_retailer,
    product_name,
    description
  FROM STAGING.STG_BUY_PRODUCTS
);

-- Verify embeddings
SELECT 
  source_retailer,
  COUNT(*) as product_count,
  COUNT(product_embedding) as embedding_count
FROM PRODUCT_EMBEDDINGS
GROUP BY source_retailer;