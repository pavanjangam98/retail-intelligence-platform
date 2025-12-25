USE ROLE ACCOUNTADMIN;
USE WAREHOUSE RETAIL_WH;
USE SCHEMA RETAIL_INTELLIGENCE_DB.ANALYTICS;

CREATE OR REPLACE VIEW RETAIL_INTELLIGENCE_SUMMARY AS
SELECT
    -- Match statistics
    (SELECT COUNT(*) FROM PRODUCT_MATCHES_AI) AS total_matches,
    (SELECT COUNT(DISTINCT abt_id) FROM PRODUCT_MATCHES_AI) AS unique_abt_matched,
    (SELECT COUNT(DISTINCT buy_id) FROM PRODUCT_MATCHES_AI) AS unique_buy_matched,
    (SELECT ROUND(AVG(semantic_similarity), 3) FROM PRODUCT_MATCHES_AI) AS avg_similarity,
    
    -- Confidence distribution
    (SELECT COUNT(*) FROM PRODUCT_MATCHES_AI WHERE match_confidence = 'HIGH') AS high_confidence_count,
    (SELECT COUNT(*) FROM PRODUCT_MATCHES_AI WHERE match_confidence = 'MEDIUM') AS medium_confidence_count,
    (SELECT COUNT(*) FROM PRODUCT_MATCHES_AI WHERE match_confidence = 'LOW') AS low_confidence_count,
    
    -- Model performance
    (SELECT ROUND(AVG(precision_pct), 2) FROM MODEL_PERFORMANCE) AS avg_precision,
    
    -- Price intelligence
    (SELECT COUNT(*) FROM PRICE_INTELLIGENCE) AS products_with_price_intel,
    (SELECT ROUND(AVG(price_diff_pct), 2) FROM PRICE_INTELLIGENCE) AS avg_price_diff_pct,
    (SELECT COUNT(*) FROM PRICE_INTELLIGENCE WHERE price_position = 'BUY is Cheaper') AS buy_cheaper_count,
    (SELECT COUNT(*) FROM PRICE_INTELLIGENCE WHERE price_position = 'ABT is Cheaper') AS abt_cheaper_count,
    
    -- Categorization
    (SELECT COUNT(DISTINCT category) FROM PRODUCT_CATEGORIES) AS unique_categories,
    (SELECT COUNT(*) FROM PRODUCT_CATEGORIES) AS products_categorized;

-- View summary
SELECT * FROM RETAIL_INTELLIGENCE_SUMMARY;