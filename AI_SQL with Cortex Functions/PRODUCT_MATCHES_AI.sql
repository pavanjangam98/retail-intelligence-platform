CREATE OR REPLACE TABLE RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI AS
WITH abt_embed AS (
  SELECT * 
  FROM PRODUCT_EMBEDDINGS
  WHERE source_retailer = 'ABT'
),
buy_embed AS (
  SELECT * 
  FROM PRODUCT_EMBEDDINGS
  WHERE source_retailer = 'BUY'
),
similarity_calc AS (
  SELECT
    a.product_id AS abt_id,
    a.product_name AS abt_name,
    a.description AS abt_description,
    a.price_numeric AS abt_price,         -- include ABT price at source
    b.product_id AS buy_id,
    b.product_name AS buy_name,
    b.description AS buy_description,
    b.price_numeric AS buy_price,         -- include BUY price at source

    VECTOR_COSINE_SIMILARITY(
      a.product_embedding, 
      b.product_embedding
    ) AS semantic_similarity
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
  END AS match_confidence,

  ROW_NUMBER() OVER (
    PARTITION BY abt_id 
    ORDER BY semantic_similarity DESC
  ) AS match_rank
FROM similarity_calc
WHERE semantic_similarity >= 0.55
ORDER BY semantic_similarity DESC;
