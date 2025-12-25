-- ============================================
-- RETAIL INTELLIGENCE PLATFORM
-- Complete SQL Scripts for All Phases
-- Team: BNZ
-- ============================================

-- ============================================
-- PHASE 1: INITIAL SETUP
-- ============================================

USE ROLE ACCOUNTADMIN;

-- Create Database
CREATE OR REPLACE DATABASE RETAIL_INTELLIGENCE_DB
  COMMENT = 'Retail Intelligence Platform for AI-powered product matching';

-- Create Schemas
CREATE OR REPLACE SCHEMA RETAIL_INTELLIGENCE_DB.RAW
  COMMENT = 'Raw data from source systems';
  
CREATE OR REPLACE SCHEMA RETAIL_INTELLIGENCE_DB.STAGING
  COMMENT = 'Cleaned and standardized data';
  
CREATE OR REPLACE SCHEMA RETAIL_INTELLIGENCE_DB.ANALYTICS
  COMMENT = 'Business logic and analytics models';
  
CREATE OR REPLACE SCHEMA RETAIL_INTELLIGENCE_DB.MART
  COMMENT = 'Aggregated data for reporting';

-- Create Warehouse
CREATE OR REPLACE WAREHOUSE RETAIL_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Warehouse for retail intelligence workloads';

USE WAREHOUSE RETAIL_WH;

-- ============================================
-- PHASE 2: RAW DATA TABLES
-- ============================================

USE SCHEMA RETAIL_INTELLIGENCE_DB.RAW;

-- ABT Products Table
CREATE OR REPLACE TABLE ABT_PRODUCTS (
  ID INTEGER NOT NULL,
  NAME VARCHAR(500),
  DESCRIPTION VARCHAR(2000),
  PRICE VARCHAR(50),
  LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_abt_id PRIMARY KEY (ID)
) COMMENT = 'Raw product data from ABT retailer';

-- BUY Products Table
CREATE OR REPLACE TABLE BUY_PRODUCTS (
  ID INTEGER NOT NULL,
  NAME VARCHAR(500),
  DESCRIPTION VARCHAR(2000),
  MANUFACTURER VARCHAR(200),
  PRICE VARCHAR(50),
  LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_buy_id PRIMARY KEY (ID)
) COMMENT = 'Raw product data from BUY retailer';

-- Ground Truth Mapping
CREATE OR REPLACE TABLE PRODUCT_MAPPING_TRUTH (
  ABT_ID INTEGER NOT NULL,
  BUY_ID INTEGER NOT NULL,
  CONSTRAINT pk_mapping PRIMARY KEY (ABT_ID, BUY_ID)
) COMMENT = 'Ground truth product matches for validation';

-- Create file format
CREATE OR REPLACE FILE FORMAT CSV_FORMAT
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('NULL', 'null', '', '\\N')
  TRIM_SPACE = TRUE
  COMMENT = 'Standard CSV format for data loading';

-- Create stage
CREATE OR REPLACE STAGE RETAIL_STAGE
  FILE_FORMAT = CSV_FORMAT
  COMMENT = 'Stage for uploading product catalog files';

-- ============================================
-- DATA LOADING COMMANDS
-- After uploading files to stage via UI or SnowSQL
-- ============================================

-- Load ABT products
COPY INTO ABT_PRODUCTS (ID, NAME, DESCRIPTION, PRICE)
FROM @RETAIL_STAGE/Abt.csv
FILE_FORMAT = CSV_FORMAT
ON_ERROR = 'CONTINUE';

-- Load BUY products  
COPY INTO BUY_PRODUCTS (ID, NAME, DESCRIPTION, MANUFACTURER, PRICE)
FROM @RETAIL_STAGE/Buy.csv
FILE_FORMAT = CSV_FORMAT
ON_ERROR = 'CONTINUE';

-- Load ground truth mappings
COPY INTO PRODUCT_MAPPING_TRUTH (ABT_ID, BUY_ID)
FROM @RETAIL_STAGE/abt_buy_perfectMapping.csv
FILE_FORMAT = CSV_FORMAT
ON_ERROR = 'CONTINUE';

-- Verify data load
SELECT 'ABT_PRODUCTS' as table_name, COUNT(*) as record_count FROM ABT_PRODUCTS
UNION ALL
SELECT 'BUY_PRODUCTS', COUNT(*) FROM BUY_PRODUCTS
UNION ALL
SELECT 'PRODUCT_MAPPING_TRUTH', COUNT(*) FROM PRODUCT_MAPPING_TRUTH;

-- ============================================
-- PHASE 3: STAGING VIEWS (DBT Alternative)
-- If not using DBT, create these views
-- ============================================

USE SCHEMA RETAIL_INTELLIGENCE_DB.STAGING;

-- Staging view for ABT products
CREATE OR REPLACE VIEW STG_ABT_PRODUCTS AS
WITH source AS (
  SELECT * FROM RETAIL_INTELLIGENCE_DB.RAW.ABT_PRODUCTS
),
cleaned AS (
  SELECT
    ID as product_id,
    TRIM(UPPER(NAME)) as product_name,
    TRIM(DESCRIPTION) as description,
    TRY_CAST(
      REPLACE(REPLACE(REPLACE(PRICE, '$', ''), ',', ''), ' ', '') 
      AS DECIMAL(10,2)
    ) as price_numeric,
    PRICE as price_raw,
    'ABT' as source_retailer,
    LOADED_AT as loaded_timestamp
  FROM source
  WHERE NAME IS NOT NULL AND TRIM(NAME) != ''
)
SELECT * FROM cleaned;

-- Staging view for BUY products
CREATE OR REPLACE VIEW STG_BUY_PRODUCTS AS
WITH source AS (
  SELECT * FROM RETAIL_INTELLIGENCE_DB.RAW.BUY_PRODUCTS
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
    LOADED_AT as loaded_timestamp
  FROM source
  WHERE NAME IS NOT NULL AND TRIM(NAME) != ''
)
SELECT * FROM cleaned;

-- Verify staging views
SELECT 'STG_ABT_PRODUCTS' as view_name, COUNT(*) as record_count FROM STG_ABT_PRODUCTS
UNION ALL
SELECT 'STG_BUY_PRODUCTS', COUNT(*) FROM STG_BUY_PRODUCTS;

-- ============================================
-- PHASE 4: AI/ML WITH CORTEX
-- ============================================

USE SCHEMA RETAIL_INTELLIGENCE_DB.ANALYTICS;

-- Create embeddings for all products
CREATE OR REPLACE TABLE PRODUCT_EMBEDDINGS AS
SELECT
  product_id,
  source_retailer,
  product_name,
  description,
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
  FROM RETAIL_INTELLIGENCE_DB.STAGING.STG_ABT_PRODUCTS
  
  UNION ALL
  
  SELECT 
    product_id,
    source_retailer,
    product_name,
    description
  FROM RETAIL_INTELLIGENCE_DB.STAGING.STG_BUY_PRODUCTS
);

-- Verify embeddings
SELECT 
  source_retailer,
  COUNT(*) as product_count,
  COUNT(product_embedding) as embedding_count
FROM PRODUCT_EMBEDDINGS
GROUP BY source_retailer;

-- Calculate semantic similarity and create matches
CREATE OR REPLACE TABLE PRODUCT_MATCHES_AI AS
WITH abt_embed AS (
  SELECT * FROM PRODUCT_EMBEDDINGS
  WHERE source_retailer = 'ABT'
),
buy_embed AS (
  SELECT * FROM PRODUCT_EMBEDDINGS
  WHERE source_retailer = 'BUY'
),
similarity_calc AS (
  SELECT
    a.product_id as abt_id,
    a.product_name as abt_name,
    a.description as abt_description,
    b.product_id as buy_id,
    b.product_name as buy_name,
    b.description as buy_description,
    VECTOR_COSINE_SIMILARITY(
      a.product_embedding, 
      b.product_embedding
    ) as semantic_similarity
  FROM abt_embed a
  CROSS JOIN buy_embed b
)
SELECT
  *,
  CASE 
    WHEN semantic_similarity >= 0.85 THEN 'HIGH'
    WHEN semantic_similarity >= 0.70 THEN 'MEDIUM'
    WHEN semantic_similarity >= 0.55 THEN 'LOW'
    ELSE 'VERY_LOW'
  END as match_confidence,
  ROW_NUMBER() OVER (
    PARTITION BY abt_id 
    ORDER BY semantic_similarity DESC
  ) as match_rank
FROM similarity_calc
WHERE semantic_similarity >= 0.55
ORDER BY semantic_similarity DESC;

-- Create index for better performance
CREATE OR REPLACE INDEX idx_match_confidence 
  ON PRODUCT_MATCHES_AI(match_confidence);

CREATE OR REPLACE INDEX idx_abt_id 
  ON PRODUCT_MATCHES_AI(abt_id);

-- AI-powered product categorization
CREATE OR REPLACE TABLE PRODUCT_CATEGORIES AS
WITH products AS (
  SELECT * FROM PRODUCT_EMBEDDINGS
),
categorized AS (
  SELECT
    product_id,
    source_retailer,
    product_name,
    SNOWFLAKE.CORTEX.COMPLETE(
      'mistral-large2',
      CONCAT(
        'Categorize this product into ONE of these categories: ',
        'Electronics, Home & Garden, Sports & Outdoors, Fashion & Accessories, ',
        'Office Supplies, Toys & Games, Health & Beauty, Automotive, Books & Media, Other. ',
        'Product: "', product_name, '". ',
        'Description: "', COALESCE(description, 'N/A'), '". ',
        'Respond with ONLY the category name, nothing else.'
      )
    ) as ai_category,
    description
  FROM products
)
SELECT
  product_id,
  source_retailer,
  product_name,
  TRIM(UPPER(ai_category)) as category,
  description,
  CURRENT_TIMESTAMP() as categorized_at
FROM categorized;

-- View category distribution
SELECT
  category,
  source_retailer,
  COUNT(*) as product_count
FROM PRODUCT_CATEGORIES
GROUP BY category, source_retailer
ORDER BY product_count DESC;

-- ============================================
-- PHASE 5: PRICE INTELLIGENCE
-- ============================================

-- Comprehensive price intelligence view
CREATE OR REPLACE VIEW PRICE_INTELLIGENCE AS
WITH matched_products AS (
  SELECT
    m.abt_id,
    m.buy_id,
    m.abt_name,
    m.buy_name,
    m.semantic_similarity,
    m.match_confidence,
    m.match_rank,
    a.price_numeric as abt_price,
    b.price_numeric as buy_price,
    ac.category as abt_category,
    bc.category as buy_category
  FROM PRODUCT_MATCHES_AI m
  JOIN RETAIL_INTELLIGENCE_DB.STAGING.STG_ABT_PRODUCTS a 
    ON m.abt_id = a.product_id
  JOIN RETAIL_INTELLIGENCE_DB.STAGING.STG_BUY_PRODUCTS b 
    ON m.buy_id = b.product_id
  LEFT JOIN PRODUCT_CATEGORIES ac 
    ON m.abt_id = ac.product_id AND ac.source_retailer = 'ABT'
  LEFT JOIN PRODUCT_CATEGORIES bc 
    ON m.buy_id = bc.product_id AND bc.source_retailer = 'BUY'
  WHERE m.match_confidence IN ('HIGH', 'MEDIUM')
    AND a.price_numeric IS NOT NULL
    AND b.price_numeric IS NOT NULL
)
SELECT
  *,
  (buy_price - abt_price) as price_difference,
  ROUND(
    ((buy_price - abt_price) / NULLIF(abt_price, 0) * 100), 
    2
  ) as price_diff_pct,
  CASE
    WHEN ABS((buy_price - abt_price) / NULLIF(abt_price, 0) * 100) < 5 
      THEN 'Price Parity'
    WHEN buy_price < abt_price 
      THEN 'BUY is Cheaper'
    ELSE 'ABT is Cheaper'
  END as price_position,
  CASE
    WHEN buy_price < abt_price 
      THEN GREATEST(0, 100 - ABS((buy_price - abt_price) / NULLIF(abt_price, 0) * 100))
    ELSE GREATEST(0, 50 - ABS((buy_price - abt_price) / NULLIF(abt_price, 0) * 100))
  END as competitiveness_score,
  COALESCE(abt_category, buy_category, 'Uncategorized') as product_category
FROM matched_products;

-- Price insights summary
CREATE OR REPLACE VIEW PRICE_INSIGHTS_SUMMARY AS
SELECT
  product_category,
  price_position,
  COUNT(*) as product_count,
  ROUND(AVG(abt_price), 2) as avg_abt_price,
  ROUND(AVG(buy_price), 2) as avg_buy_price,
  ROUND(AVG(price_diff_pct), 2) as avg_price_diff_pct,
  ROUND(AVG(competitiveness_score), 2) as avg_competitiveness,
  ROUND(MIN(abt_price), 2) as min_abt_price,
  ROUND(MAX(abt_price), 2) as max_abt_price,
  ROUND(MIN(buy_price), 2) as min_buy_price,
  ROUND(MAX(buy_price), 2) as max_buy_price
FROM PRICE_INTELLIGENCE
GROUP BY product_category, price_position
ORDER BY product_category, product_count DESC;

-- ============================================
-- PHASE 6: VALIDATION & ACCURACY
-- ============================================

-- Create validation view comparing with ground truth
CREATE OR REPLACE VIEW MATCH_VALIDATION AS
SELECT
  m.abt_id,
  m.buy_id,
  m.semantic_similarity,
  m.match_confidence,
  m.match_rank,
  CASE 
    WHEN t.abt_id IS NOT NULL THEN 'TRUE_MATCH'
    ELSE 'FALSE_MATCH'
  END as ground_truth_label
FROM PRODUCT_MATCHES_AI m
LEFT JOIN RETAIL_INTELLIGENCE_DB.RAW.PRODUCT_MAPPING_TRUTH t
  ON m.abt_id = t.abt_id AND m.buy_id = t.buy_id
WHERE m.match_confidence IN ('HIGH', 'MEDIUM', 'LOW');

-- Calculate precision by confidence level
CREATE OR REPLACE VIEW MODEL_PERFORMANCE AS
SELECT
  match_confidence,
  COUNT(*) as total_predictions,
  SUM(CASE WHEN ground_truth_label = 'TRUE_MATCH' THEN 1 ELSE 0 END) as true_positives,
  SUM(CASE WHEN ground_truth_label = 'FALSE_MATCH' THEN 1 ELSE 0 END) as false_positives,
  ROUND(
    SUM(CASE WHEN ground_truth_label = 'TRUE_MATCH' THEN 1 ELSE 0 END) * 100.0 / 
    NULLIF(COUNT(*), 0),
    2
  ) as precision_pct,
  ROUND(AVG(semantic_similarity), 4) as avg_similarity
FROM MATCH_VALIDATION
GROUP BY match_confidence
ORDER BY 
  CASE match_confidence
    WHEN 'HIGH' THEN 1
    WHEN 'MEDIUM' THEN 2
    WHEN 'LOW' THEN 3
    ELSE 4
  END;

-- Overall model performance
CREATE OR REPLACE VIEW OVERALL_PERFORMANCE AS
WITH ground_truth_stats AS (
  SELECT COUNT(*) as total_ground_truth
  FROM RETAIL_INTELLIGENCE_DB.RAW.PRODUCT_MAPPING_TRUTH
),
model_stats AS (
  SELECT
    COUNT(*) as total_predictions,
    COUNT(DISTINCT abt_id) as unique_abt_products,
    SUM(CASE WHEN match_confidence = 'HIGH' THEN 1 ELSE 0 END) as high_conf_matches,
    AVG(semantic_similarity) as avg_similarity
  FROM PRODUCT_MATCHES_AI
  WHERE match_rank = 1
),
coverage_stats AS (
  SELECT
    COUNT(DISTINCT m.abt_id) as covered_products,
    COUNT(*) as true_matches_found
  FROM PRODUCT_MATCHES_AI m
  JOIN RETAIL_INTELLIGENCE_DB.RAW.PRODUCT_MAPPING_TRUTH t
    ON m.abt_id = t.abt_id AND m.buy_id = t.buy_id
  WHERE m.match_confidence IN ('HIGH', 'MEDIUM')
)
SELECT
  g.total_ground_truth,
  m.total_predictions,
  m.unique_abt_products,
  m.high_conf_matches,
  ROUND(m.avg_similarity, 4) as avg_similarity,
  c.covered_products,
  c.true_matches_found,
  ROUND(c.true_matches_found * 100.0 / NULLIF(g.total_ground_truth, 0), 2) as recall_pct,
  ROUND(c.covered_products * 100.0 / NULLIF(m.unique_abt_products, 0), 2) as coverage_pct
FROM ground_truth_stats g, model_stats m, coverage_stats c;

-- ============================================
-- PHASE 7: ANALYTICS & REPORTING VIEWS
-- ============================================

USE SCHEMA RETAIL_INTELLIGENCE_DB.MART;

-- Top matched products
CREATE OR REPLACE VIEW TOP_MATCHES AS
SELECT
  abt_id,
  abt_name,
  buy_id,
  buy_name,
  semantic_similarity,
  match_confidence,
  match_rank
FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
WHERE match_rank <= 3
ORDER BY abt_id, match_rank;

-- Price opportunities (largest savings)
CREATE OR REPLACE VIEW PRICE_OPPORTUNITIES AS
SELECT
  abt_id,
  buy_id,
  abt_name,
  buy_name,
  product_category,
  abt_price,
  buy_price,
  price_difference,
  price_diff_pct,
  price_position,
  semantic_similarity,
  match_confidence
FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRICE_INTELLIGENCE
WHERE price_position = 'BUY is Cheaper'
  AND ABS(price_diff_pct) > 10
ORDER BY ABS(price_difference) DESC;

-- Category performance summary
CREATE OR REPLACE VIEW CATEGORY_SUMMARY AS
SELECT
  product_category,
  COUNT(DISTINCT abt_id) as abt_products,
  COUNT(DISTINCT buy_id) as buy_products,
  COUNT(*) as total_matches,
  ROUND(AVG(semantic_similarity), 3) as avg_similarity,
  ROUND(AVG(abt_price), 2) as avg_abt_price,
  ROUND(AVG(buy_price), 2) as avg_buy_price,
  ROUND(AVG(price_diff_pct), 2) as avg_price_diff_pct,
  SUM(CASE WHEN price_position = 'BUY is Cheaper' THEN 1 ELSE 0 END) as buy_cheaper_count,
  SUM(CASE WHEN price_position = 'ABT is Cheaper' THEN 1 ELSE 0 END) as abt_cheaper_count,
  SUM(CASE WHEN price_position = 'Price Parity' THEN 1 ELSE 0 END) as price_parity_count
FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRICE_INTELLIGENCE
GROUP BY product_category
ORDER BY total_matches DESC;

-- ============================================
-- PHASE 8: CORTEX ANALYST STAGE
-- ============================================

USE SCHEMA RETAIL_INTELLIGENCE_DB.ANALYTICS;

-- Create stage for Cortex Analyst
CREATE OR REPLACE STAGE CORTEX_ANALYST_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'Stage for Cortex Analyst semantic models';

-- Grant permissions
GRANT READ, WRITE ON STAGE CORTEX_ANALYST_STAGE TO ROLE ACCOUNTADMIN;

-- List files (after uploading YAML)
LIST @CORTEX_ANALYST_STAGE;

-- ============================================
-- USEFUL QUERIES FOR ANALYSIS
-- ============================================

-- Query 1: Overall statistics
SELECT 
  (SELECT COUNT(*) FROM RETAIL_INTELLIGENCE_DB.RAW.ABT_PRODUCTS) as total_abt_products,
  (SELECT COUNT(*) FROM RETAIL_INTELLIGENCE_DB.RAW.BUY_PRODUCTS) as total_buy_products,
  (SELECT COUNT(*) FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI) as total_matches,
  (SELECT COUNT(*) FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI WHERE match_confidence = 'HIGH') as high_conf_matches,
  (SELECT ROUND(AVG(semantic_similarity), 4) FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI) as avg_similarity,
  (SELECT COUNT(*) FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRICE_INTELLIGENCE) as products_with_price;

-- Query 2: Top 10 best matches
SELECT 
  abt_id,
  abt_name,
  buy_id,
  buy_name,
  ROUND(semantic_similarity, 4) as similarity,
  match_confidence
FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
ORDER BY semantic_similarity DESC
LIMIT 10;

-- Query 3: Products where BUY is significantly cheaper
SELECT 
  abt_name,
  buy_name,
  product_category,
  abt_price,
  buy_price,
  price_difference,
  ROUND(price_diff_pct, 2) as price_diff_pct
FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRICE_INTELLIGENCE
WHERE price_position = 'BUY is Cheaper'
  AND price_diff_pct < -15
ORDER BY price_diff_pct;

-- Query 4: Match quality by category
SELECT 
  pc.category,
  COUNT(*) as match_count,
  ROUND(AVG(m.semantic_similarity), 3) as avg_similarity,
  SUM(CASE WHEN m.match_confidence = 'HIGH' THEN 1 ELSE 0 END) as high_conf,
  SUM(CASE WHEN m.match_confidence = 'MEDIUM' THEN 1 ELSE 0 END) as medium_conf
FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI m
LEFT JOIN RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_CATEGORIES pc
  ON m.abt_id = pc.product_id AND pc.source_retailer = 'ABT'
GROUP BY pc.category
ORDER BY match_count DESC;

-- Query 5: Model performance summary
SELECT * FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.MODEL_PERFORMANCE;

SELECT * FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.OVERALL_PERFORMANCE;

-- ============================================
-- CLEANUP (if needed)
-- ============================================

-- DROP DATABASE RETAIL_INTELLIGENCE_DB CASCADE;
-- DROP WAREHOUSE RETAIL_WH;

-- ============================================
-- END OF SQL SCRIPTS
-- ============================================