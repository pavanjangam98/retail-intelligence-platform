import os
import json
from datetime import datetime
from airflow.decorators import dag
from airflow.operators.bash import BashOperator
from cosmos import DbtTaskGroup, ProjectConfig, ProfileConfig, ExecutionConfig, RenderConfig, LoadMode
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
target_name  = os.getenv("TARGET_NAME", "DEV").lower()
schema_name  = os.getenv("SCHEMA_NAME", "governance").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_cust_dbt/"

# ---------------------------------------------------------------------------
# Load model config
# ---------------------------------------------------------------------------
config_path = "/usr/local/airflow/dags/repo/dags/config/customer_models_loadtype_config.json"
with open(config_path, "r") as f:
    model_config = json.load(f)

model_name = "stg_alation__alation__alation_set_member"

load_type = model_config.get(model_name, {}).get("load_type", "incremental")
days_back = model_config.get(model_name, {}).get("days_back", 1)
tool_name = model_config.get(model_name, {}).get("tool_name", "airflow")

print(f"Load Type : {load_type}")
print(f"Days Back : {days_back}")

# ---------------------------------------------------------------------------
# DBT profile
# ---------------------------------------------------------------------------
profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    ),
)

dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"
manifest_path = f"{project_path}target/manifest.json"

print(f"DBT Executable Path : {dbt_executable_path}")
print(f"Manifest Path       : {manifest_path}")

# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------
@dag(
    start_date=datetime(2025, 9, 25),
    schedule="@hourly",
    catchup=False,
    tags=["hourly", "governance", "alation", "stg_alation"],
    max_active_runs=1,
)
def governance_stg_alation():
    """
    Pipeline
    --------
    Generates dbt manifest first, then runs the 6 stg_alation incremental models:
        - stg_alation__alation__alation_set_member
        - stg_alation__alation__catalog_set_membership
        - stg_alation__alation__rdbms_columns
        - stg_alation__alation__rdbms_datasources
        - stg_alation__alation__rdbms_schemas
        - stg_alation__alation__rdbms_tables
    """

    # ------------------------------------------------------------------
    # 0. Generate dbt manifest (ensures Cosmos can resolve each model
    #    as an individual task in the UI with its own logs)
    # ------------------------------------------------------------------
    generate_manifest = BashOperator(
        task_id="generate_dbt_manifest",
        bash_command=(
            f"source {os.environ['AIRFLOW_HOME']}/dbt_venv/bin/activate && "
            f"cd {project_path} && "
            f"dbt ls --profiles-dir {project_path} --target {target_name} --quiet"
        ),
    )

    # ------------------------------------------------------------------
    # 1. stg_alation — 6 incremental models
    #    LoadMode.DBT_MANIFEST ensures each model renders as a separate
    #    task node with individual logs visible in the Airflow UI.
    # ------------------------------------------------------------------
    stg_alation_dag = DbtTaskGroup(
        group_id="stg_alation_dag",
        project_config=ProjectConfig(
            project_path,
            manifest_path=manifest_path,
        ),
        profile_config=profile_config,
        execution_config=ExecutionConfig(dbt_executable_path=dbt_executable_path),
        operator_args={
            "install_deps": False,
            "vars": {
                "run_type": "incremental",
                "days_back": days_back,
                "tool_name": tool_name,
            },
        },
        render_config=RenderConfig(
            load_method=LoadMode.DBT_MANIFEST,
            select=[
                "stg_alation__alation__alation_set_member",
                "stg_alation__alation__catalog_set_membership",
                "stg_alation__alation__rdbms_columns",
                "stg_alation__alation__rdbms_datasources",
                "stg_alation__alation__rdbms_schemas",
                "stg_alation__alation__rdbms_tables",
            ],
            dbt_deps=False,
        ),
        default_args={"retries": 0},
    )

    # ------------------------------------------------------------------
    # Task chain
    # ------------------------------------------------------------------
    generate_manifest >> stg_alation_dag


governance_stg_alation()
