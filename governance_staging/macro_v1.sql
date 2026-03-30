import os
from datetime import datetime
from airflow.decorators import dag
from airflow.operators.python import PythonOperator
from airflow.models import Variable
from cosmos.operators import DbtRunOperationOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

target_name  = os.getenv("TARGET_NAME", "DEV").lower()
schema_name  = os.getenv("SCHEMA_NAME", "fdp__custmstr").lower()
project_path = "/usr/local/airflow/repo/dags/bdh_customer_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"

profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    ),
)

@dag(
    dag_id="scmcust_macro_scm_apply_tags",
    start_date=datetime(2025, 9, 25),
    schedule="0 12 * * *",
    catchup=False,
    tags=["daily", "scmcust_foundation", "fdp__custmstr"],
    max_active_runs=1,
)
def scmcust_macro_scm_apply_tags():
    def run_macro(**context):
        conf = context["dag_run"].conf or {}
        db_name    = conf.get("db_name",     Variable.get("scm_apply_tags_db_name",     default_var=None))
        schema     = conf.get("schema_name", Variable.get("scm_apply_tags_schema_name", default_var=None))
        table_name = conf.get("table_name",  Variable.get("scm_apply_tags_table_name",  default_var=None))
        since_date = conf.get("since_date",  Variable.get("scm_apply_tags_since_date",  default_var=None))

        macro_args = {}
        if db_name:    macro_args["db_name"]     = db_name
        if schema:     macro_args["schema_name"] = schema
        if table_name: macro_args["table_name"]  = table_name
        if since_date: macro_args["since_date"]  = since_date

        print(f"Running macro scm_apply_tags with args: {macro_args}")

        operator = DbtRunOperationOperator(
            task_id="run_macro_scm_apply_tags",
            project_dir=project_path,
            profile_config=profile_config,
            macro_name="scm_apply_tags",
            args=macro_args,
            dbt_executable_path=dbt_executable_path,
            install_deps=True,
            # ✅ FIX 1: Disable inlet/outlet dataset registration
            # to avoid "Operator not assigned to a DAG yet" error
            inlets=[],
            outlets=[],
        )

        # ✅ FIX 2: Explicitly assign the DAG from context
        operator.dag = context["dag"]

        operator.execute(context)

    # ✅ FIX 3: PythonOperator must be returned so Airflow registers it
    return PythonOperator(
        task_id="run_macro_scm_apply_tags",
        python_callable=run_macro,
        provide_context=True,
    )

dag_instance = scmcust_macro_scm_apply_tags()
