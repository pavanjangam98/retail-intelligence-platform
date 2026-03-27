import os
from datetime import datetime
from airflow.decorators import dag
from cosmos.operators import DbtRunOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

# Environment configs
target_name = os.getenv("TARGET_NAME", "DEV").lower()
schema_name = os.getenv("SCHEMA_NAME", "governance").lower()

project_path = "/usr/local/airflow/dags/repo/dags/bdh_governance_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"

MODEL_NAME = "foundation__fdp__custmstr__fdp__party_address"

# Snowflake profile
profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    ),
)

@dag(
    dag_id="test_dbt_model_run",
    start_date=datetime(2025, 1, 1),
    schedule=None,  # manual trigger
    catchup=False,
    tags=["test"],
)
def test_dbt_model_run():

    run_model = DbtRunOperator(
        task_id="run_dbt_model",
        project_dir=project_path,
        profile_config=profile_config,
        select=[MODEL_NAME],
        dbt_executable_path=dbt_executable_path,
    )

    run_model


dag = test_dbt_model_run()
