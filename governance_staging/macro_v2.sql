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

        # Read args from conf — None means macro uses its own defaults
        db_name    = conf.get("db_name",     None)
        schema     = conf.get("schema_name", None)
        table_name = conf.get("table_name",  None)
        since_date = conf.get("since_date",  None)

        # Only forward args that were explicitly passed
        # Never pass "" — dbt treats it as truthy and bypasses macro's none check
        macro_args = {}
        if db_name:    macro_args["db_name"]     = db_name
        if schema:     macro_args["schema_name"] = schema
        if table_name: macro_args["table_name"]  = table_name
        if since_date: macro_args["since_date"]  = since_date

        print(f"[scm_apply_tags] Resolved macro args: {macro_args}")

        operator = DbtRunOperationOperator(
            task_id="run_macro_scm_apply_tags",
            macro_name="scm_apply_tags",
            args=macro_args,
            project_dir=project_path,
            profile_config=profile_config,
            install_deps=True,
            inlets=[],   # prevents "Operator not assigned to DAG yet" error
            outlets=[],
            dbt_executable_path=dbt_executable_path,
        )

        # Inject DAG so Cosmos dataset registration doesn't fail
        operator.dag = context["dag"]
        operator.execute(context)

    PythonOperator(
        task_id="run_macro_scm_apply_tags",
        python_callable=run_macro,
        provide_context=True,
    )
