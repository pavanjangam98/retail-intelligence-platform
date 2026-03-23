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
# Models — just the model filename (same as: dbt run -m <model_name>)
# ---------------------------------------------------------------------------
MODELS = [
    "stg_alation__alation__alation_set_member",
    "stg_alation__alation__catalog_set_membership",
    "stg_alation__alation__rdbms_columns",
    "stg_alation__alation__rdbms_datasources",
    "stg_alation__alation__rdbms_schemas",
    "stg_alation__alation__rdbms_tables",
]

# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------
@dag(
    dag_id="governance_stg_alation",
    start_date=datetime(2025, 9, 25),
    schedule="@daily",
    catchup=False,
    tags=["daily", "governance", "alation"],
    max_active_runs=1,
)
def governance_stg_alation():

    task_objects = []

    for model_name in MODELS:
        t = DbtRunOperator(
            task_id=model_name,
            project_dir=project_path,
            profile_config=profile_config,
            # KEY FIX: pass ONLY the model name — same as `dbt run -m <model_name>`
            # Do NOT use dot-path like "stg_alation.model_name" — Cosmos rejects it
            models=model_name,
            vars=get_model_vars(model_name),
            dbt_executable_path=dbt_executable_path,
        )
        task_objects.append(t)

    # ----------------------------
    # Final logging task
    # ----------------------------
    @task
    def log_completion():
        print("All stg_alation models executed successfully")
        return "SUCCESS"

    # ----------------------------
    # Sequential dependency chain
    # ----------------------------
    for i in range(len(task_objects) - 1):
        task_objects[i] >> task_objects[i + 1]

    task_objects[-1] >> log_completion()


# Instantiate DAG
dag = governance_stg_alation()
