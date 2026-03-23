import os
import json
import logging
from datetime import datetime
from airflow.decorators import dag, task
from airflow.utils.dates import days_ago
from cosmos import ProjectConfig, ProfileConfig, ExecutionConfig
from cosmos.operators import DbtRunOperator, DbtTestOperator
from cosmos.profiles import SnowflakePrivateKeyPemProfileMapping

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
target_name  = os.getenv("TARGET_NAME", "DEV").lower()
schema_name  = os.getenv("SCHEMA_NAME", "governance").lower()
project_path = "/usr/local/airflow/dags/repo/dags/bdh_cust_dbt/"

# ---------------------------------------------------------------------------
# Load model config
# ---------------------------------------------------------------------------
config_path = "/usr/local/airflow/dags/repo/dags/config/governance_models_loadtype_config.json"
with open(config_path, "r") as f:
    model_config = json.load(f)

model_name = "stg_alation__alation__rdbms_tables"
load_type  = model_config.get(model_name, {}).get("load_type", "incremental")
days_back  = model_config.get(model_name, {}).get("days_back", 0)
tool_name  = model_config.get(model_name, {}).get("tool_name", "airflow")

logger.info("Load Type : %s", load_type)
logger.info("Days Back : %s", days_back)

# ---------------------------------------------------------------------------
# DBT profile
# ---------------------------------------------------------------------------
profile_config = ProfileConfig(
    profile_name="default",
    target_name=target_name,
    profile_mapping=SnowflakePrivateKeyPemProfileMapping(
        conn_id="sfconnect",
        profile_args={"schema": schema_name},
    ),
)

dbt_executable_path = f"{os.environ['AIRFLOW_HOME']}/dbt_venv/bin/dbt"
logger.info("DBT Executable Path: %s", dbt_executable_path)

# ---------------------------------------------------------------------------
# Shared dbt operator kwargs
# ---------------------------------------------------------------------------
MODELS = [
    "stg_alation__alation__alation_set_member",
    "stg_alation__alation__catalog_set_membership",
    "stg_alation__alation__rdbms_columns",
    "stg_alation__alation__rdbms_datasources",
    "stg_alation__alation__rdbms_schemas",
    "stg_alation__alation__rdbms_tables",
]

COMMON_OPERATOR_KWARGS = dict(
    project_config=ProjectConfig(project_path),
    profile_config=profile_config,
    execution_config=ExecutionConfig(dbt_executable_path=dbt_executable_path),
    install_deps=False,
    dbt_deps=False,
    vars={
        "run_type": load_type,
        "days_back": days_back,
        "tool_name": tool_name,
    },
    retries=0,
)

# ---------------------------------------------------------------------------
# Logging callbacks — surface clear PASS / FAIL lines in the DAG run log
# ---------------------------------------------------------------------------
def _on_success(context):
    model  = context["task"].task_id.replace("run__", "")
    run_id = context["run_id"]
    logger.info("=" * 70)
    logger.info("✅  MODEL COMPLETED  |  %s  |  run_id=%s", model, run_id)
    logger.info("=" * 70)


def _on_failure(context):
    model     = context["task"].task_id.replace("run__", "")
    run_id    = context["run_id"]
    exception = context.get("exception", "unknown error")
    logger.error("=" * 70)
    logger.error("❌  MODEL FAILED     |  %s  |  run_id=%s", model, run_id)
    logger.error("    Error : %s", exception)
    logger.error("=" * 70)


# ---------------------------------------------------------------------------
# DAG
# ---------------------------------------------------------------------------
@dag(
    start_date=datetime(2025, 9, 25),
    schedule="@hourly",
    catchup=False,
    tags=["hourly", "governance", "alation", "stg_alation"],
    max_active_runs=1,
)
def governance_stg_alation():
    """
    Pipeline — Sequential stg_alation incremental models
    -----------------------------------------------------
    Each model runs one after another in dependency order.
    Completion / failure of every step is surfaced in the DAG run log.

    Execution order:
        1. stg_alation__alation__alation_set_member
        2. stg_alation__alation__catalog_set_membership
        3. stg_alation__alation__rdbms_columns
        4. stg_alation__alation__rdbms_datasources
        5. stg_alation__alation__rdbms_schemas
        6. stg_alation__alation__rdbms_tables
    """

    # ------------------------------------------------------------------
    # Build one DbtRunOperator per model, all sharing the same config
    # ------------------------------------------------------------------
    run_tasks = [
        DbtRunOperator(
            task_id=f"run__{model}",
            models=model,
            on_success_callback=_on_success,
            on_failure_callback=_on_failure,
            **COMMON_OPERATOR_KWARGS,
        )
        for model in MODELS
    ]

    # ------------------------------------------------------------------
    # Chain sequentially:  task[0] >> task[1] >> ... >> task[5]
    # ------------------------------------------------------------------
    for upstream, downstream in zip(run_tasks, run_tasks[1:]):
        upstream >> downstream


governance_stg_alation()
