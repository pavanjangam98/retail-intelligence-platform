import os
import json
from datetime import datetime
from airflow.decorators import dag, task
from airflow.operators.empty import EmptyOperator
from cosmos import DbtTaskGroup, DbtDag, ProjectConfig, ProfileConfig, ExecutionConfig, RenderConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping
from cosmos.operators import DbtRunOperationOperator

# Get the environment details
is_airflow = os.getenv("IS_AIRFLOW", "true").lower()
target_name = os.getenv("TARGET_NAME", "DEV").lower()
schema_name = os.getenv("SCHEMA_NAME", "DEFAULT").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_cust_dbt/"

# Load model config from JSON
config_path = "/usr/local/airflow/dags/repo/dags/config/customer_models_loadtype_config.json"
with open(config_path, "r") as f:
    model_config = json.load(f)

model_name = "raw___bis___bst_cust_reln"

load_type = model_config.get(model_name, {}).get("load_type", "default")
look_back = model_config.get(model_name, {}).get("look_back", 30)
if look_back in [None, "", "default"]:
    look_back = 30
else:
    look_back = int(look_back)
tool_name = model_config.get(model_name, {}).get("tool_name", "airflow")

# Print values for debugging
print(f"Load Type: {load_type}")
print(f"look back: {look_back}")

# Set up profile config
profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    )
)

dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"
print(f"DBT Executable Path: {dbt_executable_path}")


# DAG definition
@dag(
    start_date=datetime(2025, 9, 25),
    schedule="@hourly",
    catchup=False,
    tags=["hourly"],
    max_active_runs=1
)
def cust_lndgtofndn_custmstr_partyrelationship():

    @task.branch(task_id="branch_raw_view_execution")
    def branch_raw_view_execution():
        if load_type.lower() == "full_data_load":
            return "raw_view_dag"
        return "skip_raw_view_dag"

    skip_raw_view_dag = EmptyOperator(
        task_id="skip_raw_view_dag"
    )

    # ------------------------------------------------------------------
    # FRESHNESS CHECK
    # ------------------------------------------------------------------
    freshness_check = DbtRunOperationOperator(
        task_id="check_source_freshness",
        macro_name="source_freshness_check",
        project_dir=project_path,
        profile_config=profile_config,
        args={
            "database":           f"LANDING__{target_name.upper()}",
            "schema":             "BIS",
            "table":              "BST_CUST_RELN",
            "error_count_non_prd": 4320,
            "error_period_non_prd": "hour",
            "error_count_prd":    25,
            "error_period_prd":   "hour",
            "ingestion_type":     "kafka",
        },
        dbt_executable_path=dbt_executable_path,
    )

    # ------------------------------------------------------------------
    # RAW VIEW  (full load only)
    # ------------------------------------------------------------------
    raw_view_dag = DbtTaskGroup(
        group_id="raw_view_dag",
        project_config=ProjectConfig(project_path),
        profile_config=profile_config,
        execution_config=ExecutionConfig(dbt_executable_path=dbt_executable_path),
        operator_args={
            "install_deps": False,
            "vars": {
                "run_type":  load_type,
                "days_back": look_back,
                "tool_name": tool_name,
            },
        },
        render_config=RenderConfig(
            select=["raw___bis___bst_cust_reln_full_view"],
            dbt_deps=False,
        ),
        default_args={"retries": 0},
    )

    join_after_raw_view = EmptyOperator(
        task_id="join_after_raw_view",
        trigger_rule="none_failed_min_one_success"
    )

    # ------------------------------------------------------------------
    # RAW DAG  (always runs)
    # ------------------------------------------------------------------
    raw_dag = DbtTaskGroup(
        group_id="raw_dag",
        project_config=ProjectConfig(project_path),
        profile_config=profile_config,
        execution_config=ExecutionConfig(dbt_executable_path=dbt_executable_path),
        operator_args={
            "install_deps": False,
            "vars": {"run_type": load_type, "days_back": look_back, "tool_name": tool_name},
        },
        render_config=RenderConfig(
            select=["raw___bis___bst_cust_reln"],
            dbt_deps=False,
        ),
        default_args={"retries": 0},
    )

    # ------------------------------------------------------------------
    # COUNT RECON  Landing → Raw  (aggregate count check)
    # ------------------------------------------------------------------
    count_check_between_raw_land = DbtRunOperationOperator(
        task_id="run_recon_check_active_records_land_to_raw",
        macro_name="custom_check_active_counts_between_raw_and_land_from_date_kafka",
        project_dir=project_path,
        profile_config=profile_config,
        args={
            "model":               "raw___bis___bst_cust_reln",
            "model_key_columns":   ["CUSTOMER1_NO", "RELATIONSHIP_TYPE", "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
            "source_name":         "landing__bis",
            "table_name":          "BST_CUST_RELN",
            "compare_key_columns": ["CUSTOMER1_NO", "RELATIONSHIP_TYPE", "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
            "ingestion_type":      "kafka",
            "load_type":           "type2",
            "look_back":           look_back,
            "raise_error":         "True",
        },
        dbt_executable_path=dbt_executable_path,
    )

    # ------------------------------------------------------------------
    # SCD2 CDC ROW-LEVEL VALIDATION  Landing → Raw
    # Validates INSERT / UPDATE / DELETE / LATE ARRIVAL row logic
    # ------------------------------------------------------------------
    scd2_cdc_validation_land_to_raw = DbtRunOperationOperator(
        task_id="run_custom_check_scd2_cdc_landing_to_raw",
        macro_name="custom_check_scd2_cdc_landing_to_raw",
        project_dir=project_path,
        profile_config=profile_config,
        args={
            "model":                      "raw___bis___bst_cust_reln",
            "source_name":                "landing__bis",
            "table_name":                 "BST_CUST_RELN",
            "key_columns":                ["CUSTOMER1_NO", "RELATIONSHIP_TYPE", "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
            "source_json_column":         "RECORD_CONTENT",
            "source_key_paths":           ["CUSTOMER1_NO", "RELATIONSHIP_TYPE", "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
            "source_key_types":           ["VARCHAR", "TRIM_VARCHAR", "TRIM_VARCHAR", "VARCHAR"],
            "source_time_path":           "metadata:time",
            "target_from_column":         "DWH_EFFECTIVE_FROM_TSTAMP",
            "target_to_column":           "DWH_EFFECTIVE_TO_TSTAMP",
            "target_deleted_flag_column": "DWH_IS_DELETED_FLAG",
            "target_dml_type_column":     "DWH_LATEST_DML_TYPE_CODE",
            "ingestion_type":             "kafka",
            "load_type":                  "type2",
            "look_back":                  look_back,
            "raise_error":                "True",
        },
        dbt_executable_path=dbt_executable_path,
    )

    # ------------------------------------------------------------------
    # FOUNDATION DAG
    # ------------------------------------------------------------------
    foundation_dag = DbtTaskGroup(
        group_id="foundation_dag",
        project_config=ProjectConfig(project_path),
        profile_config=profile_config,
        execution_config=ExecutionConfig(dbt_executable_path=dbt_executable_path),
        operator_args={
            "install_deps": False,
            "vars": {"run_type": load_type, "days_back": look_back, "tool_name": tool_name},
        },
        render_config=RenderConfig(
            select=["foundation___fdp__custmstr___fdp__party_relationship"],
            dbt_deps=False,
        ),
        default_args={"retries": 0},
    )

    # ------------------------------------------------------------------
    # FOUNDATION RECON  Raw → Foundation  (active / deleted / distinct)
    # ------------------------------------------------------------------
    active_count_recon_foundation_to_raw = DbtRunOperationOperator(
        task_id="run_recon_check_active_records",
        macro_name="fdp_custom_check_active_counts_between_models_from_date",
        project_dir=project_path,
        profile_config=profile_config,
        args={
            "model":            "foundation___fdp__custmstr___fdp__party_relationship",
            "compare_model":    "raw___bis___bst_cust_reln",
            "model_time_col":   "DWH_EFFECTIVE_FROM_TSTAMP",
            "compare_time_col": "DWH_EFFECTIVE_FROM_TSTAMP",
            "look_back":        look_back,
        },
        dbt_executable_path=dbt_executable_path,
    )

    delete_count_recon_foundation_to_raw = DbtRunOperationOperator(
        task_id="run_recon_check_deleted_records",
        macro_name="fdp_custom_check_deleted_counts_between_models_from_date",
        project_dir=project_path,
        profile_config=profile_config,
        args={
            "model":            "foundation___fdp__custmstr___fdp__party_relationship",
            "compare_model":    "raw___bis___bst_cust_reln",
            "model_time_col":   "DWH_EFFECTIVE_FROM_TSTAMP",
            "compare_time_col": "DWH_EFFECTIVE_FROM_TSTAMP",
            "look_back":        look_back,
        },
        dbt_executable_path=dbt_executable_path,
    )

    distinct_count_recon_foundation_to_raw = DbtRunOperationOperator(
        task_id="run_recon_check_distinct_records",
        macro_name="fdp_custom_check_distinct_counts_between_models_from_date",
        project_dir=project_path,
        profile_config=profile_config,
        args={
            "model":            "foundation___fdp__custmstr___fdp__party_relationship",
            "compare_model":    "raw___bis___bst_cust_reln",
            "model_columns":    ["CUSTOMER_ID", "RELATIONSHIP_TYPE_CODE", "RELATIONSHIP_CODE", "RELATED_CUSTOMER_ID"],
            "compare_columns":  ["CUSTOMER1_NO", "RELATIONSHIP_TYPE", "RELATIONSHIP_CODE", "CUSTOMER2_NO"],
            "compare_time_col": "DWH_EFFECTIVE_FROM_TSTAMP",
            "look_back":        look_back,
        },
        dbt_executable_path=dbt_executable_path,
    )

    # ------------------------------------------------------------------
    # Task chain
    #
    #  freshness_check
    #        │
    #   branch_task ───────────────────────────────────────┐
    #        │                                              │
    #   raw_view_dag                             skip_raw_view_dag
    #        └──────────── join_after_raw_view ─────────────┘
    #                               │
    #                            raw_dag
    #                               │
    #              count_check_between_raw_land        ← count recon (Landing → Raw)
    #                               │
    #              scd2_cdc_validation_land_to_raw     ← row-level SCD2 check (Landing → Raw)
    #                               │
    #                        foundation_dag
    #                               │
    #         ┌─────────────────────┼──────────────────────┐
    #  active_count_recon  delete_count_recon  distinct_count_recon
    # ------------------------------------------------------------------
    branch_task = branch_raw_view_execution()
    freshness_check >> branch_task
    branch_task >> raw_view_dag >> join_after_raw_view
    branch_task >> skip_raw_view_dag >> join_after_raw_view
    (
        join_after_raw_view
        >> raw_dag
        >> count_check_between_raw_land
        >> scd2_cdc_validation_land_to_raw
        >> foundation_dag
        >> [
            active_count_recon_foundation_to_raw,
            delete_count_recon_foundation_to_raw,
            distinct_count_recon_foundation_to_raw,
        ]
    )


cust_lndgtofndn_custmstr_partyrelationship()
