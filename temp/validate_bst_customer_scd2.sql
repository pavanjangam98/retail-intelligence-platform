{#
    MACRO: validate_bst_customer_scd2
    -----------------------------------
    Thin wrapper around compare_src_tgt_scd2() for raw___bis___bst_customer.

    Builds the source subquery using the SAME flattening logic
    (generate_json_flatten_uptoarray + select_bst_customer_fields) as the
    model itself, then hands it off to the generic comparison macro along
    with the full list of attribute columns to diff.

    Usage:
        {{ validate_bst_customer_scd2(run_type='full_data_load') }}
        {{ validate_bst_customer_scd2(run_type='specific_data_load', days_back=30) }}
#}

{% macro validate_bst_customer_scd2(run_type='specific_data_load', days_back=30) %}

{% if run_type == 'specific_data_load' %}
    {% set filter_date = "DATEADD(DAY, -" ~ days_back ~ ", CURRENT_TIMESTAMP())" %}
    {% set source_model = source('landing__bis', 'BST_CUSTOMER') %}
{% else %}
    {% set filter_date = "'1900-01-01 00:00:00'" %}
    {% set source_model = ref('raw___bis___bst_customer_full_view') %}
{% endif %}

{# All non-dwh_ attribute columns to diff between source & target #}
{% set compare_columns = [
    'customer_type','short_name','legal_name','salutation','start_date','end_date',
    'branch_no','bus_purpose_code','formal_name','corporate_no','credit_check_code',
    'cus_rate_sorc_code','cus_segment_code','cust_arch_status','cust_potn_code',
    'cust_rating_ind','ibis_base_no','ird_no','key_customer_ind','kyc_action_date',
    'kyc_staff_userid','last_chg_op_code','last_chg_timestamp','lend_category_ind',
    'mrkt_segm_code','mrkt_segment_code','non_res_levy_ind','non_resident_code',
    'origin_code','phone_id_text','prtf_status_code','prtf_status_date',
    'reas_lost_bus_desc','reas_win_bus_desc','rwt_exempt_ind','tax_code'
] %}

{% set source_subquery %}
(
    WITH raw_customer AS (
        {{ generate_json_flatten_uptoarray(
            model_name = source_model,
            json_column = 'RECORD_CONTENT')
        }}
        WHERE metadata_time::TIMESTAMP_NTZ >= {{ filter_date }}
    ),

    cte_dedupe AS (
        SELECT * FROM raw_customer
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY COALESCE(afterstate_customer_no::VARCHAR, beforestate_customer_no::VARCHAR), metadata_time::TIMESTAMP_NTZ
            ORDER BY metadata_time::TIMESTAMP_NTZ DESC) = 1
    ),

    -- afterState populated: regular insert/update
    cte_after AS (
        SELECT
            {{ select_bst_customer_fields('AFTERSTATE') }},
            metadata_time,
            'N' AS src_is_deleted_flag
        FROM cte_dedupe
        WHERE NOT IS_NULL_VALUE(record_content:afterState)
    ),

    -- beforeState populated, afterState not: delete
    cte_before AS (
        SELECT
            {{ select_bst_customer_fields('BEFORESTATE') }},
            metadata_time,
            'Y' AS src_is_deleted_flag
        FROM cte_dedupe
        WHERE IS_NULL_VALUE(record_content:afterState)
    )

    SELECT * FROM cte_after
    UNION ALL
    SELECT * FROM cte_before
)
{% endset %}

{{ compare_src_tgt_scd2(
    source_relation = source_subquery,
    target_relation = ref('raw___bis___bst_customer'),
    business_key = 'customer_no',
    source_time_col = 'metadata_time',
    compare_columns = compare_columns,
    source_is_deleted_col = 'src_is_deleted_flag'
) }}

{% endmacro %}
