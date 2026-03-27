import os
from datetime import datetime
from airflow.decorators import dag
from airflow.models import Variable
from cosmos.operators import DbtRunOperationOperator
from cosmos import ProfileConfig
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

target_name = os.getenv("TARGET_NAME", "DEV").lower()
project_path = "/usr/local/airflow/repo/dags/bdh_customer_dbt/"
dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"
schema_name = os.getenv("SCHEMA_NAME", "fdp__custmstr").lower()

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
    dag_id="scmcust_macro_scm_apply_tags",
    start_date=datetime(2025, 9, 25),
    schedule="0 12 * * *",
    catchup=False,
    tags=["daily", "scmcust_foundation", "fdp__custmstr"],
    max_active_runs=1,
)
def scmcust_macro_scm_apply_tags():

    # ✅ All 4 macro args — fetched dynamically at runtime from Airflow Variables
    # If not set, defaults to None (macro will use this.database / this.schema etc.)
    db_name     = Variable.get("scm_apply_tags_db_name",     default_var=None)
    tbl_schema  = Variable.get("scm_apply_tags_schema_name", default_var=None)
    table_name  = Variable.get("scm_apply_tags_table_name",  default_var=None)
    since_date  = Variable.get("scm_apply_tags_since_date",  default_var=None)

    # ✅ Build args dict — only pass values that are actually set
    macro_args = {}
    if db_name:    macro_args["db_name"]     = db_name
    if tbl_schema: macro_args["schema_name"] = tbl_schema
    if table_name: macro_args["table_name"]  = table_name
    if since_date: macro_args["since_date"]  = since_date

    DbtRunOperationOperator(
        task_id="run_macro_scm_apply_tags",
        project_dir=project_path,
        profile_config=profile_config,
        macro_name="scm_apply_tags",   # ✅ matches your macro name exactly
        args=macro_args,               # ✅ only passes what's set, else macro uses defaults
        dbt_executable_path=dbt_executable_path,
        install_deps=True,
    )

dag_instance = scmcust_macro_scm_apply_tags()
