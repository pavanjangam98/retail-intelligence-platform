CREATE TABLE RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI AS
WITH abt_embeddings AS (
    SELECT 
        product_id,
        product_name,
        description,
        product_embedding
    FROM PRODUCT_EMBEDDINGS
    WHERE source_retailer = 'ABT'
),
buy_embeddings AS (
    SELECT 
        product_id,
        product_name,
        description,
        product_embedding
    FROM PRODUCT_EMBEDDINGS
    WHERE source_retailer = 'BUY'
),
-- Get pricing data from staging
abt_prices AS (
    SELECT
        product_id,
        price_numeric
    FROM STAGING.STG_ABT_PRODUCTS
),
buy_prices AS (
    SELECT
        product_id,
        price_numeric
    FROM STAGING.STG_BUY_PRODUCTS
),
-- Calculate similarity for pairs with good threshold
all_similarities AS (
    SELECT
        a.product_id AS abt_id,
        a.product_name AS abt_name,
        a.description AS abt_description,
        b.product_id AS buy_id,
        b.product_name AS buy_name,
        b.description AS buy_description,
        
        -- Calculate cosine similarity
        VECTOR_COSINE_SIMILARITY(
            a.product_embedding,
            b.product_embedding
        ) AS semantic_similarity,
        
        -- Join prices
        ap.price_numeric AS abt_price,
        bp.price_numeric AS buy_price
        
    FROM abt_embeddings a
    CROSS JOIN buy_embeddings b
    LEFT JOIN abt_prices ap ON a.product_id = ap.product_id
    LEFT JOIN buy_prices bp ON b.product_id = bp.product_id
    
    -- Apply filtering
    WHERE VECTOR_COSINE_SIMILARITY(a.product_embedding, b.product_embedding) >= 0.60
),
ranked_matches AS (
    SELECT
        *,
        
        -- Calculate price metrics
        ROUND(buy_price - abt_price, 2) AS price_difference,
        
        ROUND(
            CASE 
                WHEN abt_price > 0 THEN ((buy_price - abt_price) / abt_price) * 100
                ELSE NULL
            END,
            2
        ) AS price_diff_pct,
        
        -- Price position
        CASE
            WHEN abt_price IS NULL OR buy_price IS NULL THEN 'No Price Data'
            WHEN ABS((buy_price - abt_price) / NULLIF(abt_price, 0) * 100) < 5 THEN 'Price Parity'
            WHEN buy_price < abt_price THEN 'BUY is Cheaper'
            ELSE 'ABT is Cheaper'
        END AS price_position,
        
        -- Assign confidence levels
        CASE
            WHEN semantic_similarity >= 0.85 THEN 'HIGH'
            WHEN semantic_similarity >= 0.75 THEN 'MEDIUM'
            WHEN semantic_similarity >= 0.60 THEN 'LOW'
            ELSE 'VERY_LOW'
        END AS match_confidence,
        
        -- Rank matches for each ABT product
        ROW_NUMBER() OVER (
            PARTITION BY abt_id 
            ORDER BY semantic_similarity DESC
        ) AS match_rank
        
    FROM all_similarities
)
SELECT 
    abt_id,
    buy_id,
    abt_name,
    buy_name,
    abt_description,
    buy_description,
    semantic_similarity,
    match_confidence,
    match_rank,
    abt_price,
    buy_price,
    price_difference,
    price_diff_pct,
    price_position,
    
    CURRENT_TIMESTAMP() AS created_at
    
FROM ranked_matches
WHERE match_rank <= 20
  AND match_confidence IN ('HIGH', 'MEDIUM', 'LOW')
ORDER BY abt_id, match_rank;
