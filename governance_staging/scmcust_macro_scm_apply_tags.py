from airflow.decorators import dag
from airflow.operators.python import PythonOperator

@dag(...)
def scmcust_macro_scm_apply_tags():

    def run_macro(**context):
        conf = context["dag_run"].conf or {}

        # ✅ Read from trigger JSON config, fallback to Airflow Variable
        db_name    = conf.get("db_name",    Variable.get("scm_apply_tags_db_name",    default_var=None))
        schema     = conf.get("schema_name",Variable.get("scm_apply_tags_schema_name",default_var=None))
        table_name = conf.get("table_name", Variable.get("scm_apply_tags_table_name", default_var=None))
        since_date = conf.get("since_date", Variable.get("scm_apply_tags_since_date", default_var=None))

        macro_args = {}
        if db_name:    macro_args["db_name"]     = db_name
        if schema:     macro_args["schema_name"] = schema
        if table_name: macro_args["table_name"]  = table_name
        if since_date: macro_args["since_date"]  = since_date

        DbtRunOperationOperator(
            task_id="run_macro_scm_apply_tags",
            project_dir=project_path,
            profile_config=profile_config,
            macro_name="scm_apply_tags",
            args=macro_args,
            dbt_executable_path=dbt_executable_path,
            install_deps=True,
        ).execute(context)  # ✅ execute inline since it's inside PythonOperator

    run_macro_task = PythonOperator(
        task_id="run_macro_scm_apply_tags",
        python_callable=run_macro,
    )

dag_instance = scmcust_macro_scm_apply_tags()
