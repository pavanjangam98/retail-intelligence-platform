{# Tile 1: Overall Match Statistics #}

SELECT 
    COUNT(*) as total_matches,
    COUNT(DISTINCT abt_id) as unique_abt_products,
    COUNT(DISTINCT buy_id) as unique_buy_products,
    ROUND(AVG(semantic_similarity), 3) as avg_similarity,
    SUM(CASE WHEN match_confidence = 'HIGH' THEN 1 ELSE 0 END) as high_confidence_matches,
    SUM(CASE WHEN match_confidence = 'MEDIUM' THEN 1 ELSE 0 END) as medium_confidence_matches,
    SUM(CASE WHEN match_confidence = 'LOW' THEN 1 ELSE 0 END) as low_confidence_matches
FROM ANALYTICS.PRODUCT_MATCHES_AI;

{# Tile 2: Match Confidence Distribution #}

SELECT 
    match_confidence,
    COUNT(*) as match_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) as percentage
FROM ANALYTICS.PRODUCT_MATCHES_AI
GROUP BY match_confidence
ORDER BY match_count DESC;

{# Tile 3: Similarity Score Distribution #}

SELECT 
    CASE 
        WHEN semantic_similarity >= 0.9 THEN '0.90-1.00'
        WHEN semantic_similarity >= 0.8 THEN '0.80-0.89'
        WHEN semantic_similarity >= 0.7 THEN '0.70-0.79'
        WHEN semantic_similarity >= 0.6 THEN '0.60-0.69'
        ELSE '0.50-0.59'
    END as similarity_range,
    COUNT(*) as product_count
FROM ANALYTICS.PRODUCT_MATCHES_AI
GROUP BY similarity_range
ORDER BY similarity_range DESC;

{# Tile 4: Price Position Summary #}

SELECT 
    price_position,
    COUNT(*) as product_count,
    ROUND(AVG(abt_price), 2) as avg_abt_price,
    ROUND(AVG(buy_price), 2) as avg_buy_price,
    ROUND(AVG(price_diff_pct), 2) as avg_price_diff_pct
FROM ANALYTICS.PRICE_INTELLIGENCE
GROUP BY price_position
ORDER BY product_count DESC;

{# Tile 5: Price Competitiveness by Category #}

SELECT 
    product_category,
    COUNT(*) as product_count,
    ROUND(AVG(abt_price), 2) as avg_abt_price,
    ROUND(AVG(buy_price), 2) as avg_buy_price,
    ROUND(AVG(price_diff_pct), 2) as avg_price_diff_pct,
    SUM(CASE WHEN price_position = 'BUY is Cheaper' THEN 1 ELSE 0 END) as buy_cheaper_count,
    SUM(CASE WHEN price_position = 'ABT is Cheaper' THEN 1 ELSE 0 END) as abt_cheaper_count
FROM ANALYTICS.PRICE_INTELLIGENCE
GROUP BY product_category
ORDER BY product_count DESC;

{# Tile 6: Top Price Differences #}

SELECT 
    abt_name,
    buy_name,
    product_category,
    abt_price,
    buy_price,
    price_difference,
    ROUND(price_diff_pct, 2) as price_diff_pct,
    price_position
FROM ANALYTICS.PRICE_INTELLIGENCE
ORDER BY ABS(price_diff_pct) DESC
LIMIT 20;

{# Tile 7: Category Distribution #}

SELECT 
    category,
    source_retailer,
    COUNT(*) as product_count
FROM ANALYTICS.PRODUCT_CATEGORIES
GROUP BY category, source_retailer
ORDER BY product_count DESC;

{# Tile 8: Model Performance (if ground truth available) #}

SELECT
    match_confidence,
    ground_truth_label,
    COUNT(*) as count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(PARTITION BY match_confidence), 2) as percentage
FROM ANALYTICS.MATCH_VALIDATION
GROUP BY match_confidence, ground_truth_label
ORDER BY match_confidence, ground_truth_label;