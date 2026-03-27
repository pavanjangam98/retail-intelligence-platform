import os
from datetime import datetime
from airflow.decorators import dag
from cosmos.operators import DbtRunOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

target_name = os.getenv("TARGET_NAME", "DEV").lower()
schema_name = os.getenv("SCHEMA_NAME", "fdp__custmstr").lower()
project_path = "/usr/local/airflow/repo/dags/bdh_customer_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"

MODEL_NAME = "foundation___fdp__custmstr___fdp__party_address"

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
    dag_id="scmcust_foundation_fdp_custmstr_fdp__party_address",
    start_date=datetime(2025, 9, 25),
    schedule="0 12 * * *",  # Runs daily at 12:00 PM UTC
    catchup=False,
    tags=["daily", "governance", "alation"],
    max_active_runs=1,
)
def scmcust_foundation_fdp_custmstr_fdp__party_address():

    run_model = DbtRunOperator(
        task_id="run_dbt_model",
        project_dir=project_path,
        profile_config=profile_config,
        select=[MODEL_NAME],
        dbt_executable_path=dbt_executable_path,
    )  # ✅ Fixed: closed parenthesis

    run_model  # ✅ Task registered in DAG


# ✅ Fixed: DAG instantiation call
scmcust_foundation_fdp_custmstr_fdp__party_address()

++++++++++++++


import os
from datetime import datetime
from airflow.decorators import dag
from cosmos.operators import DbtRunOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

MODEL_NAME = "foundation___fdp__custmstr___fdp__party_address"

profile_config = ProfileConfig(
    profile_name="default",
    target_name="dev",
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
    ),
)

@dag(
    dag_id="scmcust_foundation_fdp_custmstr_fdp__party_address",
    start_date=datetime(2025, 1, 1),
    schedule=None,
    catchup=False,
)
def scmcust_foundation_fdp_custmstr_fdp__party_address():

    DbtRunOperator(
        task_id="run_model",
        project_dir="/usr/local/airflow/repo/dags/bdh_customer_dbt/",
        profile_config=profile_config,
        select=MODEL_NAME,
        dbt_executable_path=f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt",
    )

dag = scmcust_foundation_fdp_custmstr_fdp__party_address()
