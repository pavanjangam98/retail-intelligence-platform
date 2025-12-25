-- Test 1: Check for null values in critical fields
SELECT 
    'ABT_PRODUCTS' as table_name,
    COUNT(*) as total_rows,
    SUM(CASE WHEN name IS NULL THEN 1 ELSE 0 END) as null_names,
    SUM(CASE WHEN price IS NULL THEN 1 ELSE 0 END) as null_prices
FROM RAW.ABT_PRODUCTS
UNION ALL
SELECT 
    'BUY_PRODUCTS',
    COUNT(*),
    SUM(CASE WHEN name IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN price IS NULL THEN 1 ELSE 0 END)
FROM RAW.BUY_PRODUCTS;

-- Test 2: Validate price conversions
SELECT 
    'ABT' as source,
    COUNT(*) as total_products,
    COUNT(price_numeric) as valid_prices,
    COUNT(*) - COUNT(price_numeric) as failed_conversions
FROM STAGING.STG_ABT_PRODUCTS
UNION ALL
SELECT 
    'BUY',
    COUNT(*),
    COUNT(price_numeric),
    COUNT(*) - COUNT(price_numeric)
FROM STAGING.STG_BUY_PRODUCTS;

-- Test 3: Validate embeddings generation
SELECT 
    source_retailer,
    COUNT(*) as total_products,
    COUNT(product_embedding) as embeddings_created,
    ROUND(COUNT(product_embedding) * 100.0 / COUNT(*), 2) as success_rate
FROM ANALYTICS.PRODUCT_EMBEDDINGS
GROUP BY source_retailer;

-- Test 4: Check match distribution
SELECT 
    match_confidence,
    COUNT(*) as match_count,
    MIN(semantic_similarity) as min_similarity,
    MAX(semantic_similarity) as max_similarity,
    AVG(semantic_similarity) as avg_similarity
FROM ANALYTICS.PRODUCT_MATCHES_AI
GROUP BY match_confidence
ORDER BY match_confidence;

-- Test 5: Validate against ground truth
SELECT 
    'Total Ground Truth' as metric,
    COUNT(*) as value
FROM RAW.PRODUCT_MAPPING_TRUTH
UNION ALL
SELECT 
    'High Confidence Matches Found',
    COUNT(*)
FROM ANALYTICS.PRODUCT_MATCHES_AI m
JOIN RAW.PRODUCT_MAPPING_TRUTH t
    ON m.abt_id = t.abt_id AND m.buy_id = t.buy_id
WHERE m.match_confidence = 'HIGH'
UNION ALL
SELECT 
    'Ground Truth Coverage %',
    ROUND(
        COUNT(DISTINCT CONCAT(m.abt_id, '-', m.buy_id)) * 100.0 / 
        (SELECT COUNT(*) FROM RAW.PRODUCT_MAPPING_TRUTH),
        2
    )
FROM ANALYTICS.PRODUCT_MATCHES_AI m
JOIN RAW.PRODUCT_MAPPING_TRUTH t
    ON m.abt_id = t.abt_id AND m.buy_id = t.buy_id;