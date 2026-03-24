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
# Load Config
# ---------------------------------------------------------------------------
config_path = "/usr/local/airflow/dags/repo/dags/config/governance_models_loadtype_config.json"

with open(config_path, "r") as f:
    model_config = json.load(f)

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------
def get_model_vars(model_name: str) -> dict:
    cfg = model_config.get(model_name, {})
    return {
        "run_type": cfg.get("load_type", "incremental"),
        "days_back": cfg.get("days_back", 0),
        "tool_name": cfg.get("tool_name", "airflow"),
    }

def get_full_refresh_flag(model_name: str) -> bool:
    return model_config.get(model_name, {}).get("load_type") == "full"

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
# Classification Model Order (IMPORTANT)
# ---------------------------------------------------------------------------
CLASSIFICATION_FLOW = [
    "governance_staging__governance_classification_data",
    "governance_classification__governance_classification_data_history",
    "governance_classification__classification_active",
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

    # ----------------------------
    # Create tasks dynamically
    # ----------------------------
    for model_name in CLASSIFICATION_FLOW:

        t = DbtRunOperator(
            task_id=model_name,
            project_dir=project_path,
            profile_config=profile_config,
            select=[model_name],
            vars=get_model_vars(model_name),
            full_refresh=get_full_refresh_flag(model_name),
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
    # Sequential execution
    # ----------------------------
    for i in range(len(task_objects) - 1):
        task_objects[i] >> task_objects[i + 1]

    task_objects[-1] >> log_completion()


# Instantiate DAG
dag = governance_classification_pipeline()
