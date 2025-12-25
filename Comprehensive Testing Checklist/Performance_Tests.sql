-- Test query performance
SELECT 
    query_text,
    execution_time / 1000 as execution_seconds,
    warehouse_name,
    rows_produced
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_text LIKE '%PRODUCT_MATCHES_AI%'
    AND start_time >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
ORDER BY execution_time DESC
LIMIT 10;