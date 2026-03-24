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
# Helper: fetch vars per model
# ---------------------------------------------------------------------------
def get_model_vars(model_name: str) -> dict:
    cfg = model_config.get(model_name, {})
    return {
        "run_type":  cfg.get("load_type", "full"),
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
# Model Names (USE ACTUAL DBT MODEL NAMES)
# ---------------------------------------------------------------------------
CLASSIFICATION_MODELS = [
    "governance_staging__governance_classification_data",              # FULL LOAD
    "governance_classification__governance_classification_data_history",  # INCREMENTAL
    "governance_classification__classification_active",               # VIEW
]

# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------
@dag(
    dag_id="governance_classification_pipeline",
    start_date=datetime(2025, 9, 25),
    schedule="@daily",
    catchup=False,
    tags=["daily", "governance", "classification"],
    max_active_runs=1,
)
def governance_classification_pipeline():

    task_objects = []

    for model_name in CLASSIFICATION_MODELS:
        vars_dict = get_model_vars(model_name)

        t = DbtRunOperator(
            task_id=model_name,
            project_dir=project_path,
            profile_config=profile_config,
            select=[model_name],
            vars=vars_dict,
            full_refresh=True if vars_dict["run_type"] == "full" else False,  # 🔥 key logic
            dbt_executable_path=dbt_executable_path,
        )

        task_objects.append(t)

    # ----------------------------
    # Final logging
    # ----------------------------
    @task
    def log_completion():
        print("Classification pipeline completed successfully")
        return "SUCCESS"

    # ----------------------------
    # Sequential dependency
    # ----------------------------
    for i in range(len(task_objects) - 1):
        task_objects[i] >> task_objects[i + 1]

    task_objects[-1] >> log_completion()


# Instantiate DAG
dag = governance_classification_pipeline()
