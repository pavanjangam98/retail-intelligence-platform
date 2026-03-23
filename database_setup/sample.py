import os
import json
from datetime import datetime
from airflow.decorators import dag, task
from cosmos.operators import DbtRunOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
target_name = os.getenv("TARGET_NAME", "DEV").lower()
schema_name = os.getenv("SCHEMA_NAME", "governance").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_governance_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"

# ---------------------------------------------------------------------------
# Load model config
# ---------------------------------------------------------------------------
config_path = "/usr/local/airflow/dags/repo/dags/config/governance_models_loadtype_config.json"

with open(config_path, "r") as f:
    model_config = json.load(f)

# ---------------------------------------------------------------------------
# Helper: fetch vars per model from config
# ---------------------------------------------------------------------------
def get_model_vars(model_name: str) -> dict:
    cfg = model_config.get(model_name, {})
    return {
        "run_type":  cfg.get("load_type", "incremental"),
        "days_back": cfg.get("days_back", 0),
        "tool_name": cfg.get("tool_name", "airflow"),
    }

# ---------------------------------------------------------------------------
# Profile Config
# ---------------------------------------------------------------------------
profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    ),
)

# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------
@dag(
    dag_id="governance_stg_alation",
    start_date=datetime(2025, 9, 25),
    schedule="@hourly",
    catchup=False,
    tags=["hourly", "governance", "alation"],
    max_active_runs=1,
)
def governance_stg_alation():

    # ----------------------------
    # Model 1
    # ----------------------------
    stg_alation_set_member = DbtRunOperator(
        task_id="stg_alation__alation__alation_set_member",
        project_dir=project_path,
        profile_config=profile_config,
        select="stg_alation__alation__alation_set_member",
        vars=get_model_vars("stg_alation__alation__alation_set_member"),
        dbt_executable_path=dbt_executable_path,
    )

    # ----------------------------
    # Model 2
    # ----------------------------
    catalog_set_membership = DbtRunOperator(
        task_id="stg_alation__alation__catalog_set_membership",
        project_dir=project_path,
        profile_config=profile_config,
        select="stg_alation__alation__catalog_set_membership",
        vars=get_model_vars("stg_alation__alation__catalog_set_membership"),
        dbt_executable_path=dbt_executable_path,
    )

    # ----------------------------
    # Model 3
    # ----------------------------
    rdbms_columns = DbtRunOperator(
        task_id="stg_alation__alation__rdbms_columns",
        project_dir=project_path,
        profile_config=profile_config,
        select="stg_alation__alation__rdbms_columns",
        vars=get_model_vars("stg_alation__alation__rdbms_columns"),
        dbt_executable_path=dbt_executable_path,
    )

    # ----------------------------
    # Model 4
    # ----------------------------
    rdbms_datasources = DbtRunOperator(
        task_id="stg_alation__alation__rdbms_datasources",
        project_dir=project_path,
        profile_config=profile_config,
        select="stg_alation__alation__rdbms_datasources",
        vars=get_model_vars("stg_alation__alation__rdbms_datasources"),
        dbt_executable_path=dbt_executable_path,
    )

    # ----------------------------
    # Model 5
    # ----------------------------
    rdbms_schemas = DbtRunOperator(
        task_id="stg_alation__alation__rdbms_schemas",
        project_dir=project_path,
        profile_config=profile_config,
        select="stg_alation__alation__rdbms_schemas",
        vars=get_model_vars("stg_alation__alation__rdbms_schemas"),
        dbt_executable_path=dbt_executable_path,
    )

    # ----------------------------
    # Model 6
    # ----------------------------
    rdbms_tables = DbtRunOperator(
        task_id="stg_alation__alation__rdbms_tables",
        project_dir=project_path,
        profile_config=profile_config,
        select="stg_alation__alation__rdbms_tables",
        vars=get_model_vars("stg_alation__alation__rdbms_tables"),
        dbt_executable_path=dbt_executable_path,
    )

    # ----------------------------
    # Final logging task
    # ----------------------------
    @task
    def log_completion():
        print("All stg_alation models executed successfully")
        return "SUCCESS"

    # ----------------------------
    # Define dependencies (sequential)
    # ----------------------------
    (
        stg_alation_set_member
        >> catalog_set_membership
        >> rdbms_columns
        >> rdbms_datasources
        >> rdbms_schemas
        >> rdbms_tables
        >> log_completion()
    )


# Instantiate DAG
dag = governance_stg_alation()
