-- analyses/audit_bst_customer_scd2.sql
--
-- Ad-hoc audit report: compile + run this to see a full row-by-row
-- comparison of expected vs actual SCD2 dates for raw___bis___bst_customer.
--
--   dbt compile --select audit_bst_customer_scd2
--   (then run the compiled SQL in target/compiled/.../audit_bst_customer_scd2.sql in Snowflake)
--
-- or, if your dbt version supports it:
--   dbt show --select audit_bst_customer_scd2 --limit 1000
--
-- Switch run_type to 'specific_data_load' to only audit the last N days
-- (matches the days_back used in your incremental loads).

{{ validate_bst_customer_scd2(run_type='full_data_load') }}

++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- tests/assert_bst_customer_scd2_valid.sql
--
-- Singular dbt test. dbt test fails if this query returns ANY rows.
-- Only rows where final_result <> 'PASS' are returned, so a failing
-- test run will show you exactly which customer_no / record_order
-- / check is broken.
--
-- Run:
--   dbt test --select assert_bst_customer_scd2_valid

SELECT *
FROM (
    {{ validate_bst_customer_scd2(run_type='full_data_load') }}
)
WHERE final_result <> 'PASS'
