import os
import json
from datetime import datetime
from airflow.decorators import dag
from cosmos import DbtTaskGroup, ProjectConfig, ProfileConfig, ExecutionConfig, RenderConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
target_name  = os.getenv("TARGET_NAME", "DEV").lower()
schema_name  = os.getenv("SCHEMA_NAME", "governance").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_governance_dbt/"

# ---------------------------------------------------------------------------
# Load model config
# ---------------------------------------------------------------------------
config_path = "/usr/local/airflow/dags/repo/dags/config/governance_models_loadtype_config.json"

with open(config_path, "r") as f:
    model_config = json.load(f)

model_name = "stg_alation__alation__rdbms_tables"

load_type = model_config.get(model_name, {}).get("load_type", "incremental")
days_back = model_config.get(model_name, {}).get("days_back", 0)
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

# DBT executable path
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"
print(f"DBT Executable Path: {dbt_executable_path}")

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
    Runs the 6 stg_alation incremental models
    """

    stg_alation_dag = DbtTaskGroup(
        group_id="stg_alation_dag",

        project_config=ProjectConfig(project_path),

        profile_config=profile_config,

        # 🔥 FIX 1: Ensure actual execution
        execution_config=ExecutionConfig(
            dbt_executable_path=dbt_executable_path,
            execution_mode="LOCAL",
        ),

        # 🔥 FIX 2: Ensure logs + proper execution args
        operator_args={
            "install_deps": False,
            "vars": {
                "run_type": load_type,
                "days_back": days_back,
                "tool_name": tool_name,
            },
            "full_refresh": False,
        },

        # 🔥 FIX 3: Prevent silent execution issues
        render_config=RenderConfig(
            select=[
                "stg_alation__alation__alation_set_member",
                "stg_alation__alation__catalog_set_membership",
                "stg_alation__alation__rdbms_columns",
                "stg_alation__alation__rdbms_datasources",
                "stg_alation__alation__rdbms_schemas",
                "stg_alation__alation__rdbms_tables",
            ],
            dbt_deps=False,
            emit_datasets=False,
        ),

        default_args={
            "retries": 0,
        },
    )

    stg_alation_dag


# Instantiate DAG
governance_stg_alation()
