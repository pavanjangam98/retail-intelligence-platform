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
SOURCE_SCHEMA = 'BPT'
CONFIG_DB = 'DB_MAIN_CONSUMPTION_DEV'
CONFIG_SCHEMA = 'PILOT_PROD_METADATA_CONFIG'
CONFIG_TABLE = 'ETL_INGEST_CONFIG'

SP_SCHEMA = f'{CONFIG_DB}.{CONFIG_SCHEMA}'

# =============================================================================
# DAG Definition - Flow for FULL/DELTA Only
# =============================================================================
with DAG(
    dag_id='qdh-snowflake_bpt_ingestion_cdc_full_delta_only_prod',
    default_args=default_args,
    description='CDC pipeline with FULL/DELTA CDC flow',
    schedule_interval='0 2 * * *',  # Run daily at 2 AM
    start_date=datetime(2026, 6, 1),
    catchup=False,
    max_active_runs=1,
    tags=['snowflake', 'cdc', 'ingestion', 'bpt'],
) as dag:

    # =========================================================================
    # TASK 1: Read All Table Configurations from Metadata Table
    # =========================================================================
    @task(task_id='get_all_configs')
    def get_all_configs(**context):
        """
        Query metadata table and return all active table configurations.
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
        ORDER BY PRIORITY, CONFIG_ID
        """
        
        print(f"Querying metadata table: {CONFIG_DB}.{CONFIG_SCHEMA}.{CONFIG_TABLE}")
        print(f"Filter: SOURCE_SCHEMA = '{SOURCE_SCHEMA}', IS_ACTIVE = TRUE")
        
        # Execute query and fetch results
        records = hook.get_records(query)
        
        if not records:
            print("⚠️ No active configurations found!")
            return []
        
        columns = [
            'CONFIG_ID', 'SOURCE_SCHEMA', 'TABLE_NAME', 'STAGING_TABLE',
            'TARGET_SCHEMA', 'STAGE_NAME', 'FILE_FORMAT', 'FILE_PATTERN',
            'LOAD_MODE', 'MERGE_KEYS', 'ON_ERROR', 'PRIORITY', 'IS_ACTIVE'
        ]
        
        # Convert to list of dicts
        all_configs = []
        for record in records:
            config = dict(zip(columns, record))
            all_configs.append(config)
        
        print(f"✓ Found {len(all_configs)} active table(s)")
        return all_configs

    # =========================================================================
    # TASK 2: Extract CDC (FULL/DELTA) Configurations
    # =========================================================================
    @task(task_id='get_cdc_configs')
    def get_cdc_configs(all_configs):
        """
        Filter and return only CDC (FULL/DELTA) configurations.
        """
        cdc_configs = [cfg for cfg in all_configs if cfg['LOAD_MODE'] in ['FULL', 'DELTA']]
        
        print(f"✓ Found {len(cdc_configs)} FULL/DELTA table(s):")
        for cfg in cdc_configs:
            print(f"  - {cfg['TABLE_NAME']} ({cfg['LOAD_MODE']})")
        
        return cdc_configs

    # =========================================================================
    # TASK 3: Validate Configurations Exist
    # =========================================================================
    @task(task_id='validate_configs_exist')
    def validate_configs_exist(all_configs):
        """
        Short-circuit the DAG if no configurations are found.
        """
        total = len(all_configs) if all_configs else 0
        
        if total == 0:
            print("❌ No configurations found - pipeline will be skipped")
            return False
        
        print(f"✓ Configuration validation passed - {total} tables to process")
        return True

    # =========================================================================
    # TASK 4: File Sensor - runs ONCE per schema (not per table)
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
                print(f"  ✓ {f}")
            if missing_mandatory:
                print(f"  Missing mandatory: {len(missing_mandatory)}")
                for f in missing_mandatory:
                    print(f"  ✗ {f}")
            
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
    # TASK 5: Validate File Sensor Results (schema-level, runs once)
    # =========================================================================
    @task(task_id='validate_file_sensor')
    def validate_file_sensor(sensor_result):
        """
        Validate schema-level file sensor results. Fails the DAG if mandatory files are missing.
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
    # CDC PATH: Load to Staging (FULL/DELTA only)
    # =========================================================================
    @task(task_id='load_to_staging')
    def load_to_staging(table_config, **context):
        """
        CDC PATH Step 1: Load files from stage to staging table.
        Calls SP_LOAD_TO_STAGING 
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)
        
        table_name = table_config['TABLE_NAME']
        run_id = f"airflow_{context['ts_nodash']}_{table_name}"
        
        # Replace {date} placeholder with actual business date
        actual_file_pattern = table_config['FILE_PATTERN'].replace('{date}', context['ds_nodash'])
        
        # Extract context values to avoid nested quotes
        dag_id = context['dag'].dag_id
        task_id = context['task'].task_id
        ds = context['ds']
        staging_table = table_config['STAGING_TABLE']
        stage_name = table_config['STAGE_NAME']
        file_format = table_config['FILE_FORMAT']
        on_error = table_config.get('ON_ERROR', 'CONTINUE')
        
        print(f"LOAD TO STAGING: {table_name}")
        print(f"  ℹ️  Audit logging: Automatic via SP_LOAD_TO_STAGING")
        
        # Call SP_LOAD_TO_STAGING 
        load_sql = f"""
        CALL {SP_SCHEMA}.SP_LOAD_TO_STAGING(
            '{run_id}',
            '{staging_table}',
            '{stage_name}',
            '{file_format}',
            '{actual_file_pattern}',
            '{on_error}',
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
            rows_loaded = load_output.get('rows_loaded', 0)
            files_loaded = load_output.get('files_loaded', 0)
            
            print(f"✓ LOAD {table_name}: {rows_loaded} rows from {files_loaded} file(s)")
            print(f"  📊 Audit logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
            
            return {
                'table_name': table_name,
                'table_config': table_config,  # Pass config forward
                'run_id': run_id,
                'rows_loaded': rows_loaded,
                'files_loaded': files_loaded,
                'load_output': load_output
            }
        except Exception as e:
            print(f"✗ LOAD {table_name}: FAILED - {str(e)}")
            print(f"  📊 Audit failure logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
            raise

    # =========================================================================
    # CDC PATH: CDC Processing (FULL/DELTA only)
    # =========================================================================
    @task(task_id='cdc_process')
    def cdc_process(load_result, **context):
        """
        CDC PATH Step 2: Perform CDC processing.
        Calls sp_cdc_process 
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)
        
        # Extract config from load_result
        table_config = load_result['table_config']
        table_name = table_config['TABLE_NAME']
        run_id = load_result['run_id']
        
        # Map LOAD_MODE to load_pattern for sp_cdc_process
        load_mode_mapping = {
            'FULL': 'FULL',
            'DELTA': 'DELTA',
            'APPEND': 'APPEND'
        }
        load_pattern = load_mode_mapping.get(table_config['LOAD_MODE'], 'FULL')
        
        # Extract context values and config to avoid nested quotes
        dag_id = context['dag'].dag_id
        task_id = context['task'].task_id
        ds = context['ds']
        target_schema = table_config['TARGET_SCHEMA']
        staging_table = table_config['STAGING_TABLE']
        merge_keys = table_config['MERGE_KEYS']
        
        print(f"CDC PROCESS: {table_name} ({load_pattern})")
        print(f"  ℹ️  Audit logging: Automatic via sp_cdc_process")
        
        # Call sp_cdc_process 
        cdc_sql = f"""
        CALL {SP_SCHEMA}.sp_cdc_process(
            '{run_id}',
            '{table_name}',
            '{target_schema}',
            '{staging_table}',
            '{merge_keys}',
            '{CONFIG_SCHEMA}',
            '{load_pattern}',
            '{dag_id}',
            '{task_id}',
            '{ds}'
        )
        """
        
        try:
            cdc_result = hook.run(
                sql=cdc_sql,
                autocommit=True,
                handler=lambda cursor: cursor.fetchone()
            )
            
            cdc_output = json.loads(cdc_result[0]) if cdc_result and cdc_result[0] else {}
            rows_inserted = cdc_output.get('rows_inserted', 0)
            rows_updated = cdc_output.get('rows_updated', 0)
            rows_deleted = cdc_output.get('rows_deleted', 0)
            
            print(f"✓ CDC {table_name}: {rows_inserted}I/{rows_updated}U/{rows_deleted}D")
            print(f"  📊 Audit logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
            
            return {
                'table_name': table_name,
                'table_config': table_config,  # Pass config forward
                'run_id': run_id,
                'rows_loaded': load_result['rows_loaded'],
                'rows_inserted': rows_inserted,
                'rows_updated': rows_updated,
                'rows_deleted': rows_deleted,
                'load_pattern': 'CDC',
                'status': 'SUCCESS'
            }
        except Exception as e:
            print(f"✗ CDC {table_name}: FAILED - {str(e)}")
            print(f"  📊 Audit failure logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
            raise

    # =========================================================================
    # CDC PATH: Refresh Live Table (FULL/DELTA only)
    # =========================================================================
    @task(task_id='refresh_live_table')
    def refresh_live_table(cdc_result, **context):
        """
        CDC PATH Step 3: Refresh the live table (_LV) for the table.
        Calls sp_refresh_lv 
        """
        hook = SnowflakeHook(snowflake_conn_id=SNOWFLAKE_CONN_ID)
        
        # Extract config from cdc_result
        table_config = cdc_result['table_config']
        table_name = table_config['TABLE_NAME']
        run_id = cdc_result['run_id']
        
        # Extract context values and config to avoid nested quotes
        dag_id = context['dag'].dag_id
        task_id = context['task'].task_id
        ds = context['ds']
        target_schema = table_config['TARGET_SCHEMA']
        merge_keys = table_config['MERGE_KEYS']
        
        print(f"REFRESH LV: {table_name}")
        print(f"  ℹ️  Audit logging: Automatic via sp_refresh_lv")
        
        # Call sp_refresh_lv 
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
            
            # sp_refresh_lv returns a plain string, not JSON
            refresh_message = refresh_result[0] if refresh_result and refresh_result[0] else "No result returned"
            
            print(f"✓ REFRESH_LV {table_name}: Complete")
            print(f"  Result: {refresh_message}")
            print(f"  📊 Audit logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
            
            return {
                'table_name': table_name,
                'run_id': run_id,
                'rows_loaded': cdc_result['rows_loaded'],
                'rows_inserted': cdc_result['rows_inserted'],
                'rows_updated': cdc_result['rows_updated'],
                'rows_deleted': cdc_result['rows_deleted'],
                'load_pattern': 'CDC',
                'status': 'SUCCESS'
            }
        except Exception as e:
            print(f"✗ REFRESH_LV {table_name}: FAILED - {str(e)}")
            print(f"  📊 Audit failure logged automatically to {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
            raise

    # =========================================================================
    # TASK: Generate Summary Report
    # =========================================================================
    @task(task_id='generate_summary')
    def generate_summary(cdc_results, **context):
        """
        Generate summary report from CDC processing.
        Logs summary to console.
        All audit logging already done by stored procedures automatically.
        """
        business_date = context['ds']
        
        success_count = 0
        failed_count = 0
        skipped_count = 0
        
        total_loaded = 0
        total_inserted = 0
        total_updated = 0
        total_deleted = 0
        
        # Handle empty or None results
        if not cdc_results:
            print("=" * 80)
            print(f"PIPELINE SUMMARY - {business_date} - No results to process")
            print("=" * 80)
            return {
                'success': 0,
                'skipped': 0,
                'failed': 0,
                'total_loaded': 0,
                'total_inserted': 0,
                'total_updated': 0,
                'total_deleted': 0
            }
        
        # Ensure cdc_results is iterable (handle edge cases)
        try:
            results_list = list(cdc_results) if not isinstance(cdc_results, list) else cdc_results
        except Exception as e:
            print(f"⚠️ Error materializing results: {e}")
            results_list = []
        
        print("=" * 80)
        print(f"PIPELINE SUMMARY - {business_date} - {len(results_list)} tables")
        print("=" * 80)
        
        for result in results_list:
            if result is None:
                skipped_count += 1
                continue
            
            table_name = result.get('table_name', 'UNKNOWN')
            status = result.get('status', 'UNKNOWN')
            load_pattern = result.get('load_pattern', 'CDC')
            
            if status == 'SUCCESS':
                success_count += 1
                
                rows_loaded = result.get('rows_loaded', 0)
                rows_inserted = result.get('rows_inserted', 0)
                rows_updated = result.get('rows_updated', 0)
                rows_deleted = result.get('rows_deleted', 0)
                
                total_loaded += rows_loaded
                total_inserted += rows_inserted
                total_updated += rows_updated
                total_deleted += rows_deleted
                
                print(f"✓ {table_name}: {rows_loaded} loaded, {rows_inserted}I/{rows_updated}U/{rows_deleted}D (CDC)")
            else:
                failed_count += 1
                error = result.get('error', 'Unknown error')
                print(f"✗ {table_name}: FAILED - {error}")
        
        print("=" * 80)
        print(f"SUCCESS: {success_count} | SKIPPED: {skipped_count} | FAILED: {failed_count}")
        print(f"Totals - Loaded: {total_loaded} | Changes: {total_inserted}I/{total_updated}U/{total_deleted}D")
        print(f"📊 Full Audit Details: {CONFIG_DB}.{CONFIG_SCHEMA}.ETL_AUDIT_LOG")
        print("=" * 80)
        
        return {
            'success': success_count,
            'skipped': skipped_count,
            'failed': failed_count,
            'total_loaded': total_loaded,
            'total_inserted': total_inserted,
            'total_updated': total_updated,
            'total_deleted': total_deleted
        }

    # =========================================================================
    # Task Flow Definition - CDC Only
    # =========================================================================
    
    # 1. Get all configs from metadata table
    all_configs = get_all_configs()
    
    # 2. Validate configs exist
    validation = validate_configs_exist(all_configs)
    
    # 3. Get CDC configs (FULL/DELTA only)
    cdc_configs = get_cdc_configs(all_configs)
    
    # 4. File sensor ONCE for entire schema, then validate
    schema_sensor_result = file_sensor_schema()
    validated_sensor = validate_file_sensor(schema_sensor_result)
    
    # =========================================================================
    # CDC PATH: validated_sensor → staging → CDC → refresh_lv (per table)
    # =========================================================================
    cdc_load_results = load_to_staging.expand(table_config=cdc_configs)
    cdc_process_results = cdc_process.expand(load_result=cdc_load_results)
    cdc_final_results = refresh_live_table.expand(cdc_result=cdc_process_results)
    
    # Generate summary after all tables complete
    summary = generate_summary(cdc_final_results)
    
    # Set dependencies
    all_configs >> validation >> [cdc_configs, schema_sensor_result]
    schema_sensor_result >> validated_sensor
    [validated_sensor, cdc_configs] >> cdc_load_results >> cdc_process_results >> cdc_final_results >> summary