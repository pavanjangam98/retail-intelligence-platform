CREATE OR REPLACE VIEW MATCH_VALIDATION AS
SELECT
  m.abt_id,
  m.buy_id,
  m.semantic_similarity,
  m.match_confidence,
  CASE 
    WHEN t.abt_id IS NOT NULL THEN 'TRUE_MATCH'
    ELSE 'FALSE_MATCH'
  END as ground_truth_label
FROM PRODUCT_MATCHES_AI m
LEFT JOIN RAW.PRODUCT_MAPPING_TRUTH t
  ON m.abt_id = t.abt_id AND m.buy_id = t.buy_id
WHERE m.match_confidence IN ('HIGH', 'MEDIUM');

-- Calculate accuracy metrics
SELECT
  match_confidence,
  COUNT(*) as total_predictions,
  SUM(CASE WHEN ground_truth_label = 'TRUE_MATCH' THEN 1 ELSE 0 END) as true_positives,
  ROUND(
    SUM(CASE WHEN ground_truth_label = 'TRUE_MATCH' THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
    2
  ) as precision_pct
FROM MATCH_VALIDATION
GROUP BY match_confidence
ORDER BY match_confidence;