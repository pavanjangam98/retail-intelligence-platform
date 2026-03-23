import os
import json
from datetime import datetime
from airflow.decorators import dag
from cosmos import DbtDag, ProjectConfig, ProfileConfig, ExecutionConfig, RenderConfig
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

# ---------------------------------------------------------------------------
# DAG (FLAT STRUCTURE)
# ---------------------------------------------------------------------------
governance_stg_alation = DbtDag(
    dag_id="governance_stg_alation",

    start_date=datetime(2025, 9, 25),
    schedule="@hourly",
    catchup=False,
    max_active_runs=1,
    tags=["hourly", "governance", "alation", "stg_alation"],

    project_config=ProjectConfig(project_path),

    profile_config=profile_config,

    execution_config=ExecutionConfig(
        dbt_executable_path=dbt_executable_path,
        execution_mode="LOCAL",
    ),

    operator_args={
        "install_deps": False,
        "vars": {
            "run_type": load_type,
            "days_back": days_back,
            "tool_name": tool_name,
        },
        "full_refresh": False,
    },

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
)
