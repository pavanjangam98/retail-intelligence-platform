import os
import json
from datetime import datetime
from airflow.decorators import dag, task
from cosmos.operators import DbtRunOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

target_name = os.getenv("TARGET_NAME", "DEV").lower()
schema_name = os.getenv("SCHEMA_NAME", "governance").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_governance_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"

config_path = f"{project_path}model_config.json"
with open(config_path, "r") as f:
    model_config = json.load(f)

MODEL_NAME = "foundation__fdp__custmstr__fdp__party_address"

profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    ),
)

@dag(
    dag_id="scmcust_foundation_fdp_custmstr_fdp__party_address",
    start_date=datetime(2025, 9, 25),
    schedule="0 13 * * *",
    catchup=False,
    tags=["daily", "governance", "classification"],
    max_active_runs=1,
)
def scmcust_foundation_fdp_custmstr_fdp__party_address():

    run_model = DbtRunOperator(
        task_id=MODEL_NAME,
        project_dir=project_path,
        profile_config=profile_config,
        select=[MODEL_NAME],
        vars=model_config.get(MODEL_NAME, {}).get("vars", {}),
        full_refresh=model_config.get(MODEL_NAME, {}).get("load_type") == "full",
        dbt_executable_path=dbt_executable_path,
    )

    @task
    def log_completion():
        print("Classification pipeline completed successfully")
        return "SUCCESS"

    run_model >> log_completion()

dag = scmcust_foundation_fdp_custmstr_fdp__party_address()
