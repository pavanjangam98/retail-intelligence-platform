from airflow import DAG
from airflow.decorators import task
from airflow.providers.snowflake.hooks.snowflake import SnowflakeHook
from datetime import datetime, timedelta
import json

# =============================================================================
# DAG Configuration
# =============================================================================
default_args = {
    'owner': 'data_engineering',
    'depends_on_past': True,
    'email_on_failure': True,
    'email_on_retry': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}

# Snowflake connection
SNOWFLAKE_CONN_ID = 'qdh_db_snowflake'

# Metadata table configuration
SOURCE_SCHEMA = 'C360'
CONFIG_DB = 'DB_MAIN_CONSUMPTION_DEV'
CONFIG_SCHEMA = 'PILOT_PROD_METADATA_CONFIG'
CONFIG_TABLE = 'ETL_INGEST_CONFIG'

SP_SCHEMA = f'{CONFIG_DB}.{CONFIG_SCHEMA}'

# =============================================================================
# DAG Definition - APPEND Load Only
# =============================================================================
with DAG(
    dag_id='qdh-snowflake_c360_ingestion_append_only_prod',
    default_args=default_args,
    description='APPEND load pipeline - direct load to target tables without CDC processing',
    schedule_interval='0 2 * * *',  # Run daily at 2 AM
    start_date=datetime(2026, 6, 1),
    catchup=False,
    max_active_runs=1,
    tags=['snowflake', 'append', 'ingestion', 'C360'],
) as dag:

    # =========================================================================
    # TASK 1: Read APPEND Table Configurations from Metadata Table
    # =========================================================================
    @task(task_id='get_append_configs')
    def get_append_configs(**context):
        """
        Query metadata table and return only APPEND configurations.
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)

        query = f"""
            SELECT
                CONFIG_ID,
                SOURCE_SCHEMA,
                TABLE_NAME,
                STAGING_TABLE,      -- Full FQN: DB.SCHEMA.TABLE
                TARGET_SCHEMA,      -- Target schema for base table
                STAGE_NAME,         -- Stage location
                FILE_FORMAT,        -- File format object
                FILE_PATTERN,       -- Pattern with {{date}} placeholder
                LOAD_MODE,          -- FULL, DELTA, APPEND
                MERGE_KEYS,         -- Comma-separated merge keys
                ON_ERROR,           -- CONTINUE, ABORT, etc.
                PRIORITY,           -- Processing order
                IS_ACTIVE
            FROM {CONFIG_DB}.{CONFIG_SCHEMA}.{CONFIG_TABLE}
            WHERE SOURCE_SCHEMA = '{SOURCE_SCHEMA}'
              AND IS_ACTIVE = TRUE
              AND LOAD_MODE = 'APPEND'
            ORDER BY PRIORITY, CONFIG_ID
        """

        print(f"Querying metadata table: {CONFIG_DB}.{CONFIG_SCHEMA}.{CONFIG_TABLE}")
        print(f"Filter: SOURCE_SCHEMA = '{SOURCE_SCHEMA}', IS_ACTIVE = TRUE, LOAD_MODE = 'APPEND'")

        # Execute query and fetch results
        records = hook.get_records(query)

        if not records:
            print("⚠️ No active APPEND configurations found!")
            return []

        columns = [
            'CONFIG_ID', 'SOURCE_SCHEMA', 'TABLE_NAME', 'STAGING_TABLE',
            'TARGET_SCHEMA', 'STAGE_NAME', 'FILE_FORMAT', 'FILE_PATTERN',
            'LOAD_MODE', 'MERGE_KEYS', 'ON_ERROR', 'PRIORITY', 'IS_ACTIVE'
        ]

        # Convert to list of dicts
        append_configs = []
        for record in records:
            config = dict(zip(columns, record))
            append_configs.append(config)

        print(f"✓ Found {len(append_configs)} active APPEND table(s):")
        for cfg in append_configs:
            print(f"  - {cfg['TABLE_NAME']}")

        return append_configs

    # =========================================================================
    # TASK 2: Validate Configurations Exist
    # =========================================================================
    @task(task_id='validate_configs_exist')
    def validate_configs_exist(append_configs):
        """
        Short-circuit the DAG if no APPEND configurations are found.
        """
        total = len(append_configs) if append_configs else 0

        if total == 0:
            print("❌ No APPEND configurations found - pipeline will be skipped")
            return False

        print(f"✓ Configuration validation passed - {total} APPEND tables to process")
        return True

    # =========================================================================
    # TASK 3: File Sensor - runs ONCE per schema (not per table)
    # =========================================================================
    @task(task_id='file_sensor_schema')
    def file_sensor_schema(**context):
        """
        Check if files exist for ALL tables in the source schema.
        Calls sp_file_sensor ONCE - it already checks all file patterns for the schema.
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)

        business_date = context['ds_nodash']  # YYYYMMDD
        dag_id = context['dag'].dag_id
        task_id = context['task'].task_id
        run_id = context['run_id']
        ds = context['ds']

        print(f"FILE SENSOR: Calling sp_file_sensor ONCE for schema {SOURCE_SCHEMA}")
        print(f"  Business Date: {business_date}")

        sensor_sql = f"""
            CALL {SP_SCHEMA}.sp_file_sensor(
                '{SOURCE_SCHEMA}',
                '{business_date}',
                '{dag_id}',
                '{task_id}',
                '{run_id}',
                '{ds}'
            )
        """

        try:
            sensor_result = hook.run(
                sql=sensor_sql,
                autocommit=True,
                handler=lambda cursor: cursor.fetchone()
            )

            sensor_output = json.loads(sensor_result[0]) if sensor_result and sensor_result[0] else {}

            status = sensor_output.get('status', 'UNKNOWN')
            found_files = sensor_output.get('found_files', [])
            missing_mandatory = sensor_output.get('missing_mandatory_files', [])

            print(f"FILE SENSOR {SOURCE_SCHEMA}: {status}")
            print(f"  Found: {len(found_files)} file(s)")
            for f in found_files:
                print(f"    ✓ {f}")

            if missing_mandatory:
                print(f"  Missing mandatory: {len(missing_mandatory)}")
                for f in missing_mandatory:
                    print(f"    ✗ {f}")

        except Exception as e:
            print(f"FILE SENSOR {SOURCE_SCHEMA}: ERROR - {str(e)}")
            sensor_output = {
                'status': 'ERROR',
                'found_files': [],
                'missing_mandatory_files': [],
                'message': f'Error calling sp_file_sensor: {str(e)}'
            }

        return {
            'source_schema': SOURCE_SCHEMA,
            'business_date': business_date,
            'sensor_result': sensor_output
        }

    # =========================================================================
    # TASK 4: Validate File Sensor Results (schema-level, runs once)
    # =========================================================================
    @task(task_id='validate_file_sensor')
    def validate_file_sensor(sensor_result):
        """
        Validate schema-level file sensor results.
        Fails the DAG if mandatory files are missing.
        """
        source_schema = sensor_result['source_schema']
        sensor_output = sensor_result['sensor_result']
        status = sensor_output.get('status')

        if status == 'PASS':
            print(f"✓ {source_schema}: All mandatory files present")
            return sensor_result
        elif status == 'FAIL':
            missing_files = sensor_output.get('missing_mandatory_files', [])
            raise ValueError(f"File sensor failed for schema {source_schema}. Missing: {missing_files}")
        else:
            raise ValueError(f"File sensor error for schema {source_schema}: {status}")

    # =========================================================================
    # TASK 5: Load APPEND Direct to Target
    # =========================================================================
    @task(task_id='load_append_direct')
    def load_append_direct(table_config, **context):
        """
        APPEND LOAD: Load files directly from stage to target table.
        Calls SP_LOAD_APPEND - no staging, CDC, or refresh needed.
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)

        table_name = table_config['TABLE_NAME']
        run_id = f"airflow_{context['ts_nodash']}_{table_name}"

        # Build target table FQN
        target_table_fqn = f"{table_config['TARGET_SCHEMA']}.{table_name}"

        # Replace {date} placeholder with actual business date
        actual_file_pattern = table_config['FILE_PATTERN'].replace('{date}', context['ds_nodash'])

        # Extract context values to avoid nested quotes in f-string
        dag_id = context['dag'].dag_id
        task_id = context['task'].task_id
        ds = context['ds']
        stage_name = table_config['STAGE_NAME']
        file_format = table_config['FILE_FORMAT']
        on_error = table_config.get('ON_ERROR', 'CONTINUE')
        merge_keys = table_config['MERGE_KEYS']

        print(f"APPEND DIRECT LOAD: {table_name}")
        print(f"  Target: {target_table_fqn}")
        print(f"  Pattern: {actual_file_pattern}")
        print(f"  ℹ️ Audit logging: Automatic via SP_LOAD_APPEND")

        # Call SP_LOAD_APPEND
        load_sql = f"""
            CALL {SP_SCHEMA}.SP_LOAD_APPEND(
                '{run_id}',
                '{target_table_fqn}',
                '{stage_name}',
                '{file_format}',
                '{actual_file_pattern}',
                '{on_error}',
                '{merge_keys}',
                '{dag_id}',
                '{task_id}',
                '{SOURCE_SCHEMA}',
                '{ds}'
            )
        """

        try:
            load_result = hook.run(
                sql=load_sql,
                autocommit=True,
                handler=lambda cursor: cursor.fetchone()
            )

            load_output = json.loads(load_result[0]) if load_result and load_result[0] else {}
            rows_inserted = load_output.get('rows_inserted', 0)
            files_loaded = load_output.get('files_loaded', 0)

            print(f"✓ APPEND DIRECT {table_name}: {rows_inserted} rows from {files_loaded} file(s)")
            print(f"  📊 Audit logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")

            return {
                'table_name': table_name,
                'table_config': table_config,
                'run_id': run_id,
                'rows_loaded': files_loaded,
                'rows_inserted': rows_inserted,
                'rows_updated': 0,
                'rows_deleted': 0,
                'load_pattern': 'APPEND',
                'status': 'SUCCESS'
            }

        except Exception as e:
            print(f"✗ APPEND DIRECT {table_name}: FAILED - {str(e)}")
            print(f"  📊 Audit failure logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
            raise

    # =========================================================================
    # TASK 6: Refresh Live Table (_LV) after APPEND load
    # =========================================================================
    @task(task_id='refresh_live_table')
    def refresh_live_table(load_result, **context):
        """
        Refresh the live table (_LV) after APPEND load completes.
        Calls sp_refresh_lv to keep the live view in sync.
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)

        table_config = load_result['table_config']
        table_name = table_config['TABLE_NAME']
        run_id = load_result['run_id']

        dag_id = context['dag'].dag_id
        task_id = context['task'].task_id
        ds = context['ds']
        target_schema = table_config['TARGET_SCHEMA']
        merge_keys = table_config['MERGE_KEYS']

        print(f"REFRESH LV: {table_name}")

        refresh_sql = f"""
            CALL {SP_SCHEMA}.sp_refresh_lv(
                '{run_id}',
                '{table_name}',
                '{target_schema}',
                '{merge_keys}',
                '{dag_id}',
                '{task_id}',
                '{ds}'
            )
        """

        try:
            refresh_result = hook.run(
                sql=refresh_sql,
                autocommit=True,
                handler=lambda cursor: cursor.fetchone()
            )

            refresh_message = refresh_result[0] if refresh_result and refresh_result[0] else "No result returned"

            print(f"REFRESH_LV {table_name}: Complete")
            print(f"  Result: {refresh_message}")

            return {
                'table_name': table_name,
                'run_id': run_id,
                'rows_loaded': load_result['rows_loaded'],
                'rows_inserted': load_result['rows_inserted'],
                'rows_updated': load_result['rows_updated'],
                'rows_deleted': load_result['rows_deleted'],
                'load_pattern': 'APPEND',
                'status': 'SUCCESS'
            }

        except Exception as e:
            print(f"APPEND DIRECT {table_name}: FAILED - {str(e)}")
            raise

    # =========================================================================
    # TASK 6: Refresh Live Table (_LV) after APPEND load
    # =========================================================================
    @task(task_id='refresh_live_table')
    def refresh_live_table(load_result, **context):
        """
        Refresh the live table (_LV) after APPEND load completes.
        Calls sp_refresh_lv to keep the live view in sync.
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)

        table_config = load_result['table_config']
        table_name = table_config['TABLE_NAME']
        run_id = load_result['run_id']

        dag_id = context['dag'].dag_id
        task_id = context['task'].task_id
        ds = context['ds']
        target_schema = table_config['TARGET_SCHEMA']
        merge_keys = table_config['MERGE_KEYS']

        print(f"REFRESH LV: {table_name}")

        refresh_sql = f"""
            CALL {SP_SCHEMA}.sp_refresh_lv(
                '{run_id}',
                '{table_name}',
                '{target_schema}',
                '{merge_keys}',
                '{dag_id}',
                '{task_id}',
                '{ds}'
            )
        """

        try:
            refresh_result = hook.run(
                sql=refresh_sql,
                autocommit=True,
                handler=lambda cursor: cursor.fetchone()
            )

            refresh_message = refresh_result[0] if refresh_result and refresh_result[0] else "No result returned"

            print(f"REFRESH_LV {table_name}: Complete")
            print(f"  Result: {refresh_message}")

            return {
                'table_name': table_name,
                'run_id': run_id,
                'rows_loaded': load_result['rows_loaded'],
                'rows_inserted': load_result['rows_inserted'],
                'rows_updated': load_result['rows_updated'],
                'rows_deleted': load_result['rows_deleted'],
                'load_pattern': 'APPEND',
                'status': 'SUCCESS'
            }

        except Exception as e:
            print(f"REFRESH_LV {table_name}: FAILED - {str(e)}")
            raise

    # =========================================================================
    # TASK 7: Generate Summary Report
    # =========================================================================
    @task(task_id='generate_summary')
    def generate_summary(all_results, **context):
        """
        Generate summary report from APPEND loads.
        """
        business_date = context['ds']

        success_count = 0
        failed_count = 0
        skipped_count = 0
        total_loaded = 0
        total_inserted = 0

        if not all_results:
            print("=" * 80)
            print(f"APPEND PIPELINE SUMMARY - {business_date} - No results to process")
            print("=" * 80)
            return {
                'success': 0,
                'skipped': 0,
                'failed': 0,
                'total_loaded': 0,
                'total_inserted': 0
            }

        try:
            results_list = list(all_results) if not isinstance(all_results, list) else all_results
        except Exception as e:
            print(f"Error materializing results: {e}")
            results_list = []

        print("=" * 80)
        print(f"APPEND PIPELINE SUMMARY - {business_date} - {len(results_list)} tables")
        print("=" * 80)

        for result in results_list:
            if result is None:
                skipped_count += 1
                continue

            table_name = result.get('table_name', 'UNKNOWN')
            status = result.get('status', 'UNKNOWN')

            if status == 'SUCCESS':
                success_count += 1
                rows_loaded = result.get('rows_loaded', 0)
                rows_inserted = result.get('rows_inserted', 0)
                total_loaded += rows_loaded
                total_inserted += rows_inserted
                print(f"  {table_name}: {rows_loaded} files loaded, {rows_inserted} rows inserted")
            else:
                failed_count += 1
                error = result.get('error', 'Unknown error')
                print(f"  {table_name}: FAILED - {error}")

        print("=" * 80)
        print(f"SUCCESS: {success_count} | SKIPPED: {skipped_count} | FAILED: {failed_count}")
        print(f"Totals - Files Loaded: {total_loaded} | Rows Inserted: {total_inserted}")
        print(f"Audit Details: {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
        print("=" * 80)

        return {
            'success': success_count,
            'skipped': skipped_count,
            'failed': failed_count,
            'total_loaded': total_loaded,
            'total_inserted': total_inserted
        }

    # =========================================================================
    # Task Flow Definition - APPEND with Live Table Refresh
    # =========================================================================

    # 1. Get APPEND configs from metadata table
    append_configs = get_append_configs()

    # 2. Validate configs exist
    validation = validate_configs_exist(append_configs)

    # 3. File sensor ONCE for entire schema, then validate
    schema_sensor_result = file_sensor_schema()
    validated_sensor = validate_file_sensor(schema_sensor_result)

    # 4. Load append direct to target (per table, after sensor passes)
    load_results = load_append_direct.expand(table_config=append_configs)

    # 5. Refresh live table (_LV) per table after load completes
    refresh_results = refresh_live_table.expand(load_result=load_results)

    # 6. Generate summary report
    summary = generate_summary(refresh_results)

    # Set dependencies
    append_configs >> validation >> schema_sensor_result >> validated_sensor
    [validated_sensor, append_configs] >> load_results >> refresh_results >> summary