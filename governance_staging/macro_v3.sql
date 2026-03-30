from airflow import DAG
import os
from datetime import datetime
from airflow.operators.python import PythonOperator
from cosmos.operators import DbtRunOperationOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

# Configurable Parameters
project_path        = "/usr/local/airflow/dags/repo/dags/bdh_customer_dbt/"
conn_id             = "sfconnect"
schema_name         = os.getenv("SCHEMA_NAME", "fdp__custmstr").lower()
target_name         = os.getenv("TARGET_NAME", "DEV").lower()
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"

# Cosmos dbt Profile Config
profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id=conn_id,
        profile_args={"schema": schema_name},
    ),
)

# DAG Definition
with DAG(
    dag_id="scmcust_macro_scm_apply_tags",
    start_date=datetime(2025, 9, 25),
    schedule_interval="0 12 * * *",
    catchup=False,
    tags=["daily", "scmcust_foundation", "fdp__custmstr"],
    default_args={"retries": 0},
) as dag:

    def run_macro(**context):
        conf = context["dag_run"].conf or {}

        # Validate mandatory fields
        missing = [f for f in ["db_name", "schema_name", "table_name"] if not conf.get(f)]
        if missing:
            raise ValueError(f"Missing mandatory fields: {missing}")

        # Build args — since_date optional
        macro_args = {
            "db_name":     conf["db_name"],
            "schema_name": conf["schema_name"],
            "table_name":  conf["table_name"],
        }
        if conf.get("since_date"):
            macro_args["since_date"] = conf["since_date"]

        DbtRunOperationOperator(
            task_id="run_macro_scm_apply_tags",
            macro_name="scm_apply_tags",
            args=macro_args,
            project_dir=project_path,
            profile_config=profile_config,
            install_deps=True,
            dbt_executable_path=dbt_executable_path,
        ).execute(context)

    PythonOperator(
        task_id="run_macro_scm_apply_tags",
        python_callable=run_macro,
        provide_context=True,
    )
