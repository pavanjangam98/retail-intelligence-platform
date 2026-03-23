import os
import json
from datetime import datetime
from airflow.decorators import dag, task
from cosmos import ProfileConfig
from cosmos.operators import DbtRunOperator
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping
import pendulum

# ------------------------
# Shared Config
# ------------------------
target_name = os.getenv("TARGET_NAME", "DEV").lower()
schema_name  = os.getenv("SCHEMA_NAME", "governance").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_governance_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"
local_nz = pendulum.timezone("Pacific/Auckland")

# ------------------------
# Load model config
# ------------------------
config_path = "/usr/local/airflow/dags/repo/dags/config/governance_models_loadtype_config.json"

with open(config_path, "r") as f:
    model_config = json.load(f)

model_name = "stg_alation__alation__rdbms_columns"
cfg        = model_config.get(model_name, {})

load_type = cfg.get("load_type", "incremental")
days_back = cfg.get("days_back", 0)
tool_name = cfg.get("tool_name", "airflow")

# ------------------------
# Profile Config
# ------------------------
profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    ),
)

# ------------------------
# DAG
# ------------------------
@dag(
    dag_id="governance_stg_alation_rdbms_columns",
    start_date=datetime(2025, 9, 25, tzinfo=local_nz),
    schedule="@daily",
    catchup=False,
    tags=["daily", "governance", "alation"],
    description="Daily refresh for stg_alation__alation__rdbms_columns",
    max_active_runs=1,
)
def governance_stg_alation_rdbms_columns():

    run_rdbms_columns = DbtRunOperator(
        task_id="stg_alation__alation__rdbms_columns",
        project_dir=project_path,
        profile_config=profile_config,
        # FIX: dbt 1.11+ requires `select` not `models`
        select=model_name,
        vars={
            "run_type":  load_type,
            "days_back": days_back,
            "tool_name": tool_name,
        },
        dbt_executable_path=dbt_executable_path,
    )

    @task
    def log_completion():
        print("Successfully ran model: stg_alation__alation__rdbms_columns")
        return "SUCCESS"

    run_rdbms_columns >> log_completion()


# Instantiate the DAG
dag = governance_stg_alation_rdbms_columns()
