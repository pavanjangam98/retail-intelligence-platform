-- Comprehensive price intelligence
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
  JOIN STAGING.STG_ABT_PRODUCTS a ON m.abt_id = a.product_id
  JOIN STAGING.STG_BUY_PRODUCTS b ON m.buy_id = b.product_id
  LEFT JOIN PRODUCT_CATEGORIES ac 
    ON m.abt_id = ac.product_id AND ac.source_retailer = 'ABT'
  LEFT JOIN PRODUCT_CATEGORIES bc 
    ON m.buy_id = bc.product_id AND bc.source_retailer = 'BUY'
  WHERE m.match_confidence IN ('HIGH', 'MEDIUM')
)
SELECT
  *,
  -- Price calculations
  (buy_price - abt_price) as price_difference,
  ROUND(
    ((buy_price - abt_price) / abt_price * 100), 
    2
  ) as price_diff_pct,
  -- Price position
  CASE
    WHEN ABS((buy_price - abt_price) / abt_price * 100) < 5 
      THEN 'Price Parity'
    WHEN buy_price < abt_price 
      THEN 'BUY is Cheaper'
    ELSE 'ABT is Cheaper'
  END as price_position,
  -- Price competitiveness score (0-100)
  CASE
    WHEN buy_price < abt_price 
      THEN GREATEST(0, 100 - ABS((buy_price - abt_price) / abt_price * 100))
    ELSE GREATEST(0, 50 - ABS((buy_price - abt_price) / abt_price * 100))
  END as competitiveness_score,
  -- Coalesce categories
  COALESCE(abt_category, buy_category, 'Uncategorized') as product_category
FROM matched_products;

-- Price insights summary
SELECT
  product_category,
  price_position,
  COUNT(*) as product_count,
  ROUND(AVG(abt_price), 2) as avg_abt_price,
  ROUND(AVG(buy_price), 2) as avg_buy_price,
  ROUND(AVG(price_diff_pct), 2) as avg_price_diff_pct,
  ROUND(AVG(competitiveness_score), 2) as avg_competitiveness
FROM PRICE_INTELLIGENCE
GROUP BY product_category, price_position
ORDER BY product_category, product_count DESC;