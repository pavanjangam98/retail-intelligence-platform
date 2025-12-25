-- Use Cortex Complete for product categorization
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
    ) as ai_category
  FROM products
)
SELECT
  *,
  -- Clean up AI response
  TRIM(UPPER(ai_category)) as category,
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