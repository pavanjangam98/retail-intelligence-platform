import os
import json
from datetime import datetime
from airflow.decorators import dag, task
from cosmos.operators import DbtRunOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
target_name = os.getenv("TARGET_NAME", "DEV").lower()
schema_name = os.getenv("SCHEMA_NAME", "governance").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_governance_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"

# Model list
MODEL_LIST = [
    "stg_alation__alation__alation_set_member",
    "stg_alation__alation__catalog_set_membership",
    "stg_alation__alation__rdbms_columns",
    "stg_alation__alation__rdbms_datasources",
    "stg_alation__alation__rdbms_schemas",
    "stg_alation__alation__rdbms_tables",
]

# Profile
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
    max_active_runs=1,
    tags=["governance", "dbt"],
)
def governance_stg_alation():

    tasks = []

    # Create one task per model
    for model in MODEL_LIST:
        task = DbtRunOperator(
            task_id=model,
            project_dir=project_path,
            profile_config=profile_config,
            select=[model],   # 🔥 important: list format
            dbt_executable_path=dbt_executable_path,
        )
        tasks.append(task)

    # Optional: run in sequence
    for i in range(len(tasks) - 1):
        tasks[i] >> tasks[i + 1]

    # Final log
    @task
    def done():
        print("All models executed")

    tasks[-1] >> done()


dag = governance_stg_alation()
