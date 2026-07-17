CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_END("P_AUDIT_ID" NUMBER(38,0), "P_SOURCE_ROW_COUNT" NUMBER(38,0) DEFAULT null, "P_TARGET_ROW_COUNT" NUMBER(38,0) DEFAULT null, "P_ROWS_INSERTED" NUMBER(38,0) DEFAULT null, "P_ROWS_UPDATED" NUMBER(38,0) DEFAULT null, "P_ROWS_DELETED" NUMBER(38,0) DEFAULT null, "P_FILES_LOADED" NUMBER(38,0) DEFAULT null, "P_JOB_STATUS" VARCHAR DEFAULT 'SUCCESS')
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS '
BEGIN
    UPDATE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.ETL_AUDIT_LOG
    SET JOB_STATUS = :P_JOB_STATUS,
        JOB_END_TIME = CURRENT_TIMESTAMP(),
        SOURCE_ROW_COUNT = :P_SOURCE_ROW_COUNT,
        TARGET_ROW_COUNT = :P_TARGET_ROW_COUNT,
        ROWS_INSERTED = :P_ROWS_INSERTED,
        ROWS_UPDATED = :P_ROWS_UPDATED,
        ROWS_DELETED = :P_ROWS_DELETED,
        FILES_LOADED = :P_FILES_LOADED
    WHERE AUDIT_ID = :P_AUDIT_ID;

    COMMIT;

    RETURN ''Audit logged successfully for audit_id='' || :P_AUDIT_ID;
END;
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_FAILURE("P_AUDIT_ID" NUMBER(38,0), "P_ERROR_MESSAGE" VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS '
BEGIN
    UPDATE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.ETL_AUDIT_LOG
    SET JOB_STATUS = ''FAILED'',
        JOB_END_TIME = CURRENT_TIMESTAMP(),
        ERROR_MESSAGE = SUBSTR(:P_ERROR_MESSAGE, 1, 16777216)
    WHERE AUDIT_ID = :P_AUDIT_ID;

    COMMIT;

    RETURN ''Audit failure logged for audit_id='' || :P_AUDIT_ID;
END;
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_START("P_DAG_NAME" VARCHAR, "P_TASK_NAME" VARCHAR, "P_RUN_ID" VARCHAR, "P_PROCESSING_DATE" DATE, "P_SOURCE_SCHEMA" VARCHAR, "P_TABLE_NAME" VARCHAR, "P_TARGET_SCHEMA" VARCHAR, "P_STAGE_NAME" VARCHAR, "P_PROCEDURE_NAME" VARCHAR)
RETURNS NUMBER(38,0)
LANGUAGE SQL
EXECUTE AS CALLER
AS '
DECLARE
    V_AUDIT_ID NUMBER;
BEGIN
    INSERT INTO DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.ETL_AUDIT_LOG (
        DAG_NAME,
        TASK_NAME,
        RUN_ID,
        EXECUTION_DATE,
        PROCESSING_DATE,
        SOURCE_SCHEMA,
        TABLE_NAME,
        TARGET_SCHEMA,
        STAGE_NAME,
        PROCEDURE_NAME,
        JOB_STATUS,
        JOB_START_TIME
    )
    VALUES (
        COALESCE(:P_DAG_NAME, ''MANUAL''),
        COALESCE(:P_TASK_NAME, ''UNKNOWN''),
        :P_RUN_ID,
        CURRENT_TIMESTAMP(),
        COALESCE(:P_PROCESSING_DATE, CURRENT_DATE()),
        :P_SOURCE_SCHEMA,
        :P_TABLE_NAME,
        :P_TARGET_SCHEMA,
        :P_STAGE_NAME,
        :P_PROCEDURE_NAME,
        ''STARTED'',
        CURRENT_TIMESTAMP()
    );

    SELECT MAX(AUDIT_ID) INTO :V_AUDIT_ID
    FROM DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.ETL_AUDIT_LOG
    WHERE RUN_ID = :P_RUN_ID
      AND PROCEDURE_NAME = :P_PROCEDURE_NAME
      AND COALESCE(TABLE_NAME, '''') = COALESCE(:P_TABLE_NAME, '''');

    RETURN :V_AUDIT_ID;
END;
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_CDC_PROCESS("RUN_ID" VARCHAR, "TABLE_NAME" VARCHAR, "TARGET_SCHEMA" VARCHAR, "STAGING_TABLE_FQN" VARCHAR, "MERGE_KEYS" VARCHAR, "CONFIG_SCHEMA" VARCHAR, "LOAD_PATTERN" VARCHAR DEFAULT 'FULL', "DAG_NAME" VARCHAR DEFAULT null, "TASK_NAME" VARCHAR DEFAULT null, "PROCESSING_DATE" DATE DEFAULT null)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'cdc_process'
EXECUTE AS CALLER
AS '
import json
import logging

log = logging.getLogger(__name__)

def cdc_process(session, run_id, table_name, target_schema, staging_table_fqn, merge_keys, config_schema, load_pattern=''FULL'',
               dag_name=None, task_name=None, processing_date=None):
    """
    CDC processing: Compare staging vs _LV, detect I/U/D, append to base table.
    Uses separate audit SPs for logging.
    """
    
    # AUDIT START
    audit_id = None
    try:
        parts = staging_table_fqn.split(''.'')
        source_schema = f"{parts[0]}.{parts[1]}" if len(parts) == 3 else parts[0]
        
        audit_result = session.call(
            ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_START'',
            dag_name,
            task_name or ''cdc_process'',
            run_id,
            processing_date,
            source_schema,
            table_name,
            target_schema,
            None,
            ''sp_cdc_process''
        )
        audit_id = audit_result if audit_result else None
        log.info(f"[sp_cdc_process] Audit start logged: audit_id={audit_id}")
    except Exception as e:
        log.warning(f"[sp_cdc_process] Failed to log audit start: {e}")
    
    # MAIN CDC LOGIC
    try:
        full_table = f"{target_schema}.{table_name}"
        lv_table = f"{target_schema}.{table_name}_LV"
        merge_key_list = [k.strip() for k in merge_keys.split('','')]
        
        log.info(f"[sp_cdc_process] Starting CDC for {full_table}")
        
        query_tag = {"procedure": "sp_cdc_process", "run_id": run_id, "table": table_name}
        try:
            session.sql(f"ALTER SESSION SET QUERY_TAG = ''{json.dumps(query_tag)}''").collect()
        except:
            pass
        
        desc_result = session.sql(f"DESC TABLE {full_table}").collect()
        all_columns = [row[''name''] for row in desc_result]
        
        # Detect filename column variant (FILENAME, HDP_FILENAME, or FILE_NAME)
        filename_variants = {''FILENAME'', ''HDP_FILENAME'', ''FILE_NAME''}
        filename_column = None
        for col in all_columns:
            if col in filename_variants:
                filename_column = col
                break
        
        # Separate business columns from metadata columns
        metadata_columns = {''HDP_LAST_UPDT_TSTAMP'', ''HDP_LAST_UPDT_USER'', ''HDP_DML_CODE'', ''ROW_HASH''}
        if filename_column:
            metadata_columns.add(filename_column)
        data_columns = [col for col in all_columns if col not in metadata_columns]
        
        log.info(f"[sp_cdc_process] Data columns for hash: {data_columns}")
        log.info(f"[sp_cdc_process] Total columns: {len(all_columns)}, Data columns: {len(data_columns)}, Filename column: {filename_column}")
        
        # Check if _LV exists
        try:
            lv_check = session.sql(f"SELECT COUNT(*) as cnt FROM {lv_table}").collect()
            lv_exists = True
            lv_row_count = lv_check[0][''CNT''] if lv_check else 0
        except:
            lv_exists = False
            lv_row_count = 0
        
        hash_columns = ", ".join([f"stg.{col}" for col in data_columns])
        merge_key_join = " AND ".join([f"lv.{key} = stg.{key}" for key in merge_key_list])
        insert_columns = ", ".join(all_columns)
        data_columns_select = ", ".join([f"stg.{col}" for col in data_columns])
        
        log.info(f"[sp_cdc_process] lv_exists={lv_exists}, lv_row_count={lv_row_count}, load_pattern={load_pattern}")
        log.info(f"[sp_cdc_process] Staging table: {staging_table_fqn}, LV table: {lv_table}")
        
        if not lv_exists or lv_row_count == 0:
            filename_select = f"stg.{filename_column}," if filename_column else ""
            insert_sql = f"""
            INSERT INTO {full_table} ({insert_columns})
            SELECT 
                {data_columns_select},
                {filename_select}
                stg.HDP_LAST_UPDT_TSTAMP,
                stg.HDP_LAST_UPDT_USER,
                ''I'' AS HDP_DML_CODE,
                HASH({hash_columns}) AS ROW_HASH
            FROM {staging_table_fqn} stg
            """
        else:
            if load_pattern == ''FULL'':
                where_clause = """
                (lv.{merge_key} IS NULL)
                OR (stg.{merge_key} IS NULL AND lv.HDP_DML_CODE != ''D'')
                OR (stg.calculated_hash IS NOT NULL AND lv.ROW_HASH IS NOT NULL AND stg.calculated_hash != lv.ROW_HASH)
                """
            elif load_pattern == ''DELTA'':
                where_clause = """
                (lv.{merge_key} IS NULL)
                OR (stg.calculated_hash IS NOT NULL AND lv.ROW_HASH IS NOT NULL AND stg.calculated_hash != lv.ROW_HASH AND stg.{merge_key} IS NOT NULL)
                """
            elif load_pattern == ''APPEND'':
                where_clause = """
                (lv.{merge_key} IS NULL)
                """
            else:
                raise ValueError(f"Invalid load_pattern: {load_pattern}")
            
            where_clause = where_clause.format(merge_key=merge_key_list[0])
            
            # Build DML_CODE logic based on load_pattern
            if load_pattern == ''FULL'':
                dml_code_logic = f"""
                    CASE
                        WHEN lv.{merge_key_list[0]} IS NULL THEN ''I''
                        WHEN stg.{merge_key_list[0]} IS NULL THEN ''D''
                        WHEN stg.calculated_hash != lv.ROW_HASH THEN ''U''
                        ELSE NULL
                    END AS HDP_DML_CODE"""
            elif load_pattern == ''DELTA'':
                dml_code_logic = f"""
                    CASE
                        WHEN lv.{merge_key_list[0]} IS NULL THEN ''I''
                        WHEN stg.{merge_key_list[0]} IS NOT NULL AND stg.calculated_hash != lv.ROW_HASH THEN ''U''
                        ELSE NULL
                    END AS HDP_DML_CODE"""
            elif load_pattern == ''APPEND'':
                dml_code_logic = f"""
                    CASE
                        WHEN lv.{merge_key_list[0]} IS NULL THEN ''I''
                        ELSE NULL
                    END AS HDP_DML_CODE"""
            
            # Build filename select conditionally
            filename_select = f"COALESCE(stg.{filename_column}, (SELECT MIN({filename_column}) FROM {staging_table_fqn})) AS {filename_column}," if filename_column else ""
            
            insert_sql = f"""
            INSERT INTO {full_table} ({insert_columns})
            WITH staging_with_hash AS (
                SELECT *,
                    HASH({hash_columns}) AS calculated_hash
                FROM {staging_table_fqn} stg
            ),
            cdc_full_outer AS (
                SELECT
                    {'', ''.join([f''COALESCE(stg.{col}, lv.{col}) AS {col}'' for col in data_columns])},
                    {filename_select}
                    COALESCE(stg.HDP_LAST_UPDT_TSTAMP, CURRENT_TIMESTAMP()) AS HDP_LAST_UPDT_TSTAMP,
                    COALESCE(stg.HDP_LAST_UPDT_USER, ''Informatica'') AS HDP_LAST_UPDT_USER,
                    {dml_code_logic},
                    COALESCE(stg.calculated_hash, lv.ROW_HASH) AS ROW_HASH
                FROM staging_with_hash stg
                FULL OUTER JOIN {lv_table} lv
                    ON {merge_key_join}
                WHERE {where_clause}
            )
            SELECT * FROM cdc_full_outer
            """
        
        # Get breakdown BEFORE insert
        rows_inserted = 0
        rows_updated = 0
        rows_deleted = 0
        
        try:
            if not lv_exists or lv_row_count == 0:
                count_result = session.sql(f"SELECT COUNT(*) FROM {staging_table_fqn}").collect()
                rows_inserted = count_result[0][0] if count_result else 0
            else:
                breakdown_sql = f"""
                WITH staging_with_hash AS (
                    SELECT *,
                        HASH({hash_columns}) AS calculated_hash
                    FROM {staging_table_fqn} stg
                ),
                cdc_full_outer AS (
                    SELECT
                        {dml_code_logic}
                    FROM staging_with_hash stg
                    FULL OUTER JOIN {lv_table} lv
                        ON {merge_key_join}
                    WHERE {where_clause}
                )
                SELECT HDP_DML_CODE, COUNT(*) AS row_count
                FROM cdc_full_outer
                WHERE HDP_DML_CODE IS NOT NULL
                GROUP BY HDP_DML_CODE
                """
                
                breakdown_result = session.sql(breakdown_sql).collect()
                
                for row in breakdown_result:
                    op = row[''HDP_DML_CODE'']
                    count = row[''ROW_COUNT'']
                    if op == ''I'':
                        rows_inserted = count
                    elif op == ''U'':
                        rows_updated = count
                    elif op == ''D'':
                        rows_deleted = count
                        
            log.info(f"[sp_cdc_process] Pre-insert breakdown: {rows_inserted}I/{rows_updated}U/{rows_deleted}D")
        except Exception as e:
            log.warning(f"[sp_cdc_process] Breakdown query failed: {e}. Will use 0s.")
        
        # Now do the actual insert
        insert_result = session.sql(insert_sql).collect()
        rows_inserted_total = insert_result[0][''number of rows inserted''] if insert_result else 0
        
        log.info(f"[sp_cdc_process] Actual rows inserted to target: {rows_inserted_total}")
        log.info(f"[sp_cdc_process] CDC complete: {rows_inserted}I/{rows_updated}U/{rows_deleted}D")
        
        result = {
            "run_id": run_id,
            "rows_inserted": rows_inserted,
            "rows_updated": rows_updated,
            "rows_deleted": rows_deleted,
            "total_changes_appended": rows_inserted + rows_updated + rows_deleted
        }
        
        # AUDIT END - Success
        if audit_id:
            source_result = session.sql(f"SELECT COUNT(*) FROM {staging_table_fqn}").collect()
            source_count = source_result[0][0] if source_result else 0
            
            target_result = session.sql(f"SELECT COUNT(*) FROM {full_table}").collect()
            target_count = target_result[0][0] if target_result else 0
            
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_END'',
                audit_id,
                source_count,
                target_count,
                rows_inserted,
                rows_updated,
                rows_deleted,
                None,
                ''SUCCESS''
            )
            
            log.info(f"[sp_cdc_process] Audit updated to SUCCESS for audit_id={audit_id}")
        
        return result
        
    except Exception as exc:
        error_msg = str(exc)
        log.error(f"[sp_cdc_process] ERROR: {error_msg}")
        
        # AUDIT END - Failure
        if audit_id:
            error_escaped = error_msg.replace("''", "''''")[:16777216]
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_FAILURE'',
                audit_id,
                error_escaped
            )
            log.info(f"[sp_cdc_process] Audit updated to FAILED for audit_id={audit_id}")
        
        raise
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_FILE_SENSOR("SOURCE_SCHEMA" VARCHAR, "BUSINESS_DATE" VARCHAR, "DAG_NAME" VARCHAR DEFAULT null, "TASK_NAME" VARCHAR DEFAULT null, "AIRFLOW_RUN_ID" VARCHAR DEFAULT null, "PROCESSING_DATE" DATE DEFAULT null)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'file_sensor'
EXECUTE AS CALLER
AS '
import json
import logging

log = logging.getLogger(__name__)

def file_sensor(session, source_schema, business_date, 
               dag_name, task_name, airflow_run_id, processing_date):
    """
    File sensor - checks for file presence on stage.
    NO audit logging per SME requirements (only data processing SPs need audit).
    """
    
    try:
        log.info(f"[sp_file_sensor] Checking files for {source_schema} on {business_date}")
        
        # ✅ ONLY CHANGE: Use fully qualified table name (same as Airflow)
        config_sql = f"""
            SELECT 
                SOURCE_SCHEMA as source_schema,
                FILE_PATTERN,
                STAGE_NAME as stage_path,
                Filecheck_is_mandatory as is_mandatory,
                NOTES as file_description
            FROM DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.ETL_INGEST_CONFIG
            WHERE SOURCE_SCHEMA = ''{source_schema}'' AND IS_ACTIVE = TRUE
            ORDER BY is_mandatory DESC, FILE_PATTERN
        """
        
        config_result = session.sql(config_sql).collect()
        
        if not config_result:
            raise ValueError(f"No configuration found for source system: {source_schema}")
        
        log.info(f"[sp_file_sensor] Checking {len(config_result)} file patterns")
        
        missing_mandatory = []
        missing_optional = []
        found_files = []
        all_checks = []
        
        for row in config_result:
            file_pattern = row[''FILE_PATTERN''].replace(''{date}'', business_date)
            stage_path = row[''STAGE_PATH'']
            is_mandatory = row[''IS_MANDATORY'']
            
            try:
                list_result = session.sql(f"LIST {stage_path} PATTERN = ''.*{file_pattern}''").collect()
                file_found = len(list_result) > 0
                
                check = {
                    "pattern": file_pattern,
                    "stage": stage_path,
                    "mandatory": is_mandatory,
                    "found": file_found,
                    "count": len(list_result)
                }
                
                if file_found:
                    files = [r[''name''].split(''/'')[-1] for r in list_result]
                    check["files"] = files
                    found_files.extend(files)
                    log.info(f"[sp_file_sensor] ✓ Found: {files}")
                else:
                    if is_mandatory:
                        missing_mandatory.append(file_pattern)
                        log.warning(f"[sp_file_sensor] ✗ Missing (MANDATORY): {file_pattern}")
                    else:
                        missing_optional.append(file_pattern)
                
                all_checks.append(check)
                
            except Exception as e:
                log.warning(f"[sp_file_sensor] Error checking {file_pattern}: {str(e)}")
                if is_mandatory:
                    missing_mandatory.append(file_pattern)
        
        status = "FAIL" if missing_mandatory else "PASS"
        log.info(f"[sp_file_sensor] Overall status: {status}")
        
        result = {
            "source_schema": source_schema,
            "business_date": business_date,
            "status": status,
            "mandatory_missing": len(missing_mandatory),
            "missing_mandatory_files": missing_mandatory,
            "missing_optional_files": missing_optional,
            "found_files": found_files,
            "checks": all_checks
        }
        
        return result
        
    except Exception as e:
        error_msg = str(e)
        log.error(f"[sp_file_sensor] ERROR: {error_msg}")
        
        return {
            "status": "FAILED",
            "source_schema": source_schema,
            "business_date": business_date,
            "error": error_msg
        }
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_LOAD_APPEND("RUN_ID" VARCHAR, "TARGET_TABLE_FQN" VARCHAR, "STAGE_NAME" VARCHAR, "FILE_FORMAT" VARCHAR, "FILE_PATTERN" VARCHAR, "ON_ERROR" VARCHAR, "MERGE_KEYS" VARCHAR, "DAG_NAME" VARCHAR DEFAULT null, "TASK_NAME" VARCHAR DEFAULT null, "SRC_SCHEMA" VARCHAR DEFAULT null, "PROCESSING_DATE" DATE DEFAULT null)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'load_append'
EXECUTE AS CALLER
AS '
import json
import logging

log = logging.getLogger(__name__)

def load_append(session, run_id, target_table_fqn, stage_name, file_format, 
                       file_pattern, on_error, merge_keys, dag_name, task_name, 
                       src_schema, processing_date):
    """
    APPEND-only pattern: Load CSV files directly from stage to target table.
    Uses separate audit SPs for logging.
    """
    
    table_name = target_table_fqn.split(''.'')[-1] if ''.'' in target_table_fqn else target_table_fqn
    parts = target_table_fqn.split(''.'')
    target_schema = f"{parts[0]}.{parts[1]}" if len(parts) == 3 else parts[0]
    
    merge_key_list = [k.strip() for k in merge_keys.split('','')]
    
    # AUDIT START
    audit_id = None
    try:
        audit_result = session.call(
            ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_START'',
            dag_name,
            task_name or ''load_append'',
            run_id,
            processing_date,
            src_schema or target_schema,
            table_name,
            target_schema,
            stage_name,
            ''sp_load_append''
        )
        audit_id = audit_result if audit_result else None
        log.info(f"[sp_load_append] Audit start logged: audit_id={audit_id}")
    except Exception as e:
        log.warning(f"[sp_load_append] Failed to log audit start: {e}")
    
    # MAIN LOGIC - Direct Load to Target
    try:
        pattern_sql = f"PATTERN = ''{file_pattern}''" if file_pattern and file_pattern != ''.*'' else ""
        
        log.info(f"[sp_load_append] Run ID: {run_id}")
        log.info(f"[sp_load_append] Target table: {target_table_fqn}")
        log.info(f"[sp_load_append] Merge keys: {merge_keys}")
        
        query_tag = {"procedure": "sp_load_append", "run_id": run_id, "table": table_name}
        try:
            session.sql(f"ALTER SESSION SET QUERY_TAG = ''{json.dumps(query_tag)}''").collect()
        except:
            pass
        
        # Get target table schema
        desc_result = session.sql(f"DESC TABLE {target_table_fqn}").collect()
        
        business_columns = []
        filename_column = None
        filename_variants = (''FILENAME'', ''HDP_FILENAME'', ''FILE_NAME'')
        
        for row in desc_result:
            col_name = row[''name'']
            
            if col_name in filename_variants:
                filename_column = col_name
            elif col_name not in [''HDP_LAST_UPDT_TSTAMP'', ''HDP_LAST_UPDT_USER'', 
                                   ''HDP_DML_CODE'']:
                business_columns.append(col_name)
        
        csv_column_count = len(business_columns)
        
        # Build SELECT statement for COPY INTO
        csv_columns = [f''${i+1}'' for i in range(csv_column_count)]
        select_parts = csv_columns.copy()
        
        if filename_column:
            select_parts.append(f"METADATA$FILENAME AS {filename_column}")
        
        select_parts.append("CURRENT_TIMESTAMP() AS HDP_LAST_UPDT_TSTAMP")
        select_parts.append("''INFORMATICA'' AS HDP_LAST_UPDT_USER")
        select_parts.append("''I'' AS HDP_DML_CODE")
        
        select_list = '',\\n            ''.join(select_parts)
        
        # Build target column list
        target_columns = business_columns.copy()
        if filename_column:
            target_columns.append(filename_column)
        target_columns.extend([''HDP_LAST_UPDT_TSTAMP'', ''HDP_LAST_UPDT_USER'', 
                               ''HDP_DML_CODE''])
        
        target_column_list = '', ''.join(target_columns)
        
        # Execute COPY INTO
        copy_sql = f"""
        COPY INTO {target_table_fqn} ({target_column_list})
        FROM (
            SELECT
            {select_list}
            FROM {stage_name}
        )
        FILE_FORMAT = (FORMAT_NAME = {file_format})
        {pattern_sql}
        ON_ERROR = {on_error}
        """
        
        log.info(f"[sp_load_append] Executing direct load...")
        
        raw = session.sql(copy_sql).collect()
        
        rows_loaded = 0
        files_ok = 0
        files_fail = 0
        file_results = []
        
        for r in raw:
            rd = r.as_dict()
            rows_loaded += int(rd.get(''rows_loaded'', 0) or 0)
            
            if rd.get(''status'') == ''LOADED'':
                files_ok += 1
            else:
                files_fail += 1
            
            file_results.append(rd)
        
        log.info(f"[sp_load_append] Loaded {rows_loaded} rows from {files_ok} files directly to target")
        
        # Get final row count
        count_result = session.sql(f"SELECT COUNT(*) FROM {target_table_fqn}").collect()
        total_rows = count_result[0][0] if count_result else 0
        
        result = {
            "run_id": run_id,
            "table_name": table_name,
            "rows_inserted": rows_loaded,
            "files_loaded": files_ok,
            "files_failed": files_fail,
            "total_rows_in_target": total_rows,
            "file_results": file_results,
            "load_pattern": "APPEND"
        }
        
        # AUDIT END - Success
        if audit_id:
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_END'',
                audit_id,
                rows_loaded,
                total_rows,
                rows_loaded,
                0,
                0,
                files_ok,
                ''SUCCESS''
            )
            
            log.info(f"[sp_load_append] Audit updated to SUCCESS for audit_id={audit_id}")
        
        return result
        
    except Exception as exc:
        error_msg = str(exc)
        log.error(f"[sp_load_append] ERROR: {error_msg}")
        
        # AUDIT END - Failure
        if audit_id:
            error_escaped = error_msg.replace("''", "''''")[:16777216]
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_FAILURE'',
                audit_id,
                error_escaped
            )
            log.info(f"[sp_load_append] Audit updated to FAILED for audit_id={audit_id}")
        
        raise
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_LOAD_TO_STAGING("RUN_ID" VARCHAR, "STAGING_TABLE_FQN" VARCHAR, "STAGE_NAME" VARCHAR, "FILE_FORMAT" VARCHAR, "FILE_PATTERN" VARCHAR, "ON_ERROR" VARCHAR, "DAG_NAME" VARCHAR DEFAULT null, "TASK_NAME" VARCHAR DEFAULT null, "SRC_SCHEMA" VARCHAR DEFAULT null, "PROCESSING_DATE" DATE DEFAULT null)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'load_to_staging'
EXECUTE AS CALLER
AS '
import json
import logging

log = logging.getLogger(__name__)

def load_to_staging(session, run_id, staging_table_fqn, stage_name, file_format, file_pattern, on_error,
                   dag_name, task_name, src_schema, processing_date):
    """
    Generic procedure to load CSV files from stage to any staging table.
    Uses separate audit SPs for logging.
    """
    
    table_name = staging_table_fqn.split(''.'')[-1] if ''.'' in staging_table_fqn else staging_table_fqn
    parts = staging_table_fqn.split(''.'')
    target_schema = f"{parts[0]}.{parts[1]}" if len(parts) == 3 else parts[0]
    
    # AUDIT START
    audit_id = None
    try:
        audit_result = session.call(
            ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_START'',
            dag_name,
            task_name or ''load_to_staging'',
            run_id,
            processing_date,
            src_schema,
            table_name,
            target_schema,
            stage_name,
            ''sp_load_to_staging''
        )
        audit_id = audit_result if audit_result else None
        log.info(f"[sp_load_to_staging] Audit start logged: audit_id={audit_id}")
    except Exception as e:
        log.warning(f"[sp_load_to_staging] Failed to log audit start: {e}")
    
    # MAIN LOGIC
    try:
        pattern_sql = f"PATTERN = ''{file_pattern}''" if file_pattern and file_pattern != ''.*'' else ""
        
        log.info(f"[sp_load_to_staging] Run ID: {run_id}")
        log.info(f"[sp_load_to_staging] Staging table: {staging_table_fqn}")
        
        query_tag = {"procedure": "sp_load_to_staging", "run_id": run_id, "table": table_name}
        try:
            session.sql(f"ALTER SESSION SET QUERY_TAG = ''{json.dumps(query_tag)}''").collect()
        except:
            pass
        
        # Truncate staging table
        session.sql(f"TRUNCATE TABLE IF EXISTS {staging_table_fqn}").collect()
        
        # Get columns dynamically - detect filename column variant
        desc_result = session.sql(f"DESC TABLE {staging_table_fqn}").collect()
        business_columns = []
        filename_column = None
        filename_variants = {''FILENAME'', ''HDP_FILENAME'', ''FILE_NAME''}
        
        for row in desc_result:
            col_name = row[''name'']
            if col_name in filename_variants:
                filename_column = col_name
            elif col_name not in [''HDP_LAST_UPDT_TSTAMP'', ''HDP_LAST_UPDT_USER'', ''HDP_DML_CODE'', ''ROW_HASH'']:
                business_columns.append(col_name)
        
        csv_column_count = len(business_columns)
        csv_select_list = '', ''.join([f''${i+1}'' for i in range(csv_column_count)])
        target_columns = business_columns.copy()
        
        if filename_column:
            target_columns.append(filename_column)
            select_list = f"{csv_select_list}, METADATA$FILENAME"
        else:
            select_list = csv_select_list
        
        target_column_list = '', ''.join(target_columns)
        
        # Load files from stage
        copy_sql = f"""
        COPY INTO {staging_table_fqn} ({target_column_list})
        FROM (
            SELECT {select_list}
            FROM {stage_name}
        )
        FILE_FORMAT = (FORMAT_NAME = {file_format})
        {pattern_sql}
        ON_ERROR = {on_error}
        """
        
        raw = session.sql(copy_sql).collect()
        
        rows_loaded = 0
        files_ok = 0
        files_fail = 0
        file_results = []
        
        for r in raw:
            rd = r.as_dict()
            rows_loaded += int(rd.get(''rows_loaded'', 0) or 0)
            if rd.get(''status'') == ''LOADED'':
                files_ok += 1
            else:
                files_fail += 1
            file_results.append(rd)
        
        log.info(f"[sp_load_to_staging] Loaded {rows_loaded} rows from {files_ok} files")
        
        result = {
            "run_id": run_id,
            "rows_loaded": rows_loaded,
            "files_loaded": files_ok,
            "files_failed": files_fail,
            "file_results": file_results
        }
        
        # AUDIT END - Success
        if audit_id:
            count_result = session.sql(f"SELECT COUNT(*) FROM {staging_table_fqn}").collect()
            staging_count = count_result[0][0] if count_result else 0
            
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_END'',
                audit_id,
                staging_count,
                staging_count,
                rows_loaded,
                0,
                0,
                files_ok,
                ''SUCCESS''
            )
            
            log.info(f"[sp_load_to_staging] Audit updated to SUCCESS for audit_id={audit_id}")
        
        return result
        
    except Exception as exc:
        error_msg = str(exc)
        log.error(f"[sp_load_to_staging] ERROR: {error_msg}")
        
        # AUDIT END - Failure
        if audit_id:
            error_escaped = error_msg.replace("''", "''''")[:16777216]
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_FAILURE'',
                audit_id,
                error_escaped
            )
            log.info(f"[sp_load_to_staging] Audit updated to FAILED for audit_id={audit_id}")
        
        raise
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
CREATE OR REPLACE PROCEDURE DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_REFRESH_LV("RUN_ID" VARCHAR, "TABLE_NAME" VARCHAR, "TARGET_SCHEMA" VARCHAR, "MERGE_KEYS" VARCHAR, "DAG_NAME" VARCHAR DEFAULT null, "TASK_NAME" VARCHAR DEFAULT null, "PROCESSING_DATE" DATE DEFAULT null)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'refresh_lv'
EXECUTE AS CALLER
AS '
import json
import logging

log = logging.getLogger(__name__)

def refresh_lv(session, run_id, table_name, target_schema, merge_keys,
              dag_name=None, task_name=None, processing_date=None):
    """
    Rebuild _LV table with latest active records.
    Uses separate audit SPs for logging.
    """
    
    full_table = f"{target_schema}.{table_name}"
    lv_table = f"{target_schema}.{table_name}_LV"
    
    # AUDIT START - Call audit SP with FULLY QUALIFIED NAME
    audit_id = None
    try:
        audit_result = session.call(
            ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_START'',
            dag_name,
            task_name or ''refresh_lv'',
            run_id,
            processing_date,
            target_schema,
            f"{table_name}_LV",
            target_schema,
            None,  # stage_name
            ''sp_refresh_lv''
        )
        audit_id = audit_result if audit_result else None
        log.info(f"[sp_refresh_lv] Audit start logged: audit_id={audit_id}")
    except Exception as e:
        log.warning(f"[sp_refresh_lv] Failed to log audit start: {e}")
    
    # MAIN LOGIC
    try:
        merge_key_list = [k.strip() for k in merge_keys.split('','')]
        partition_by = ", ".join(merge_key_list)
        
        log.info(f"[sp_refresh_lv] Rebuilding {lv_table} from {full_table}")
        
        query_tag = {"procedure": "sp_refresh_lv", "run_id": run_id, "table": table_name}
        try:
            session.sql(f"ALTER SESSION SET QUERY_TAG = ''{json.dumps(query_tag)}''").collect()
        except:
            pass
        
        desc_result = session.sql(f"DESC TABLE {full_table}").collect()
        all_columns = [row[''name''] for row in desc_result]
        column_select = ", ".join(all_columns)
        
        lv_sql = f"""
        CREATE OR REPLACE TABLE {lv_table} AS
        SELECT {column_select}
        FROM (
            SELECT
                a.*,
                RANK() OVER (
                    PARTITION BY {partition_by}
                    ORDER BY a.HDP_LAST_UPDT_TSTAMP DESC,
                             CASE
                                 WHEN a.HDP_DML_CODE = ''D'' THEN 3
                                 WHEN a.HDP_DML_CODE = ''U'' THEN 2
                                 WHEN a.HDP_DML_CODE = ''I'' THEN 1
                                 ELSE 0
                             END DESC
                ) AS seqnum
            FROM {full_table} a
        ) ca
        WHERE seqnum = 1
          AND HDP_DML_CODE != ''D''
        """
        
        session.sql(lv_sql).collect()
        
        count_result = session.sql(f"SELECT COUNT(*) FROM {lv_table}").collect()
        row_count = count_result[0][0] if count_result else 0
        
        log.info(f"[sp_refresh_lv] SUCCESS: {lv_table} rebuilt with {row_count} active records")
        
        # AUDIT END - Success - Call audit SP with FULLY QUALIFIED NAME
        if audit_id:
            # Get source row count (base table before LV rebuild)
            source_result = session.sql(f"SELECT COUNT(*) FROM {full_table}").collect()
            source_count = source_result[0][0] if source_result else 0
            
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_END'',
                audit_id,
                source_count,  # P_SOURCE_ROW_COUNT (base table rows)
                row_count,     # P_TARGET_ROW_COUNT (LV table rows)
                None,          # P_ROWS_INSERTED
                None,          # P_ROWS_UPDATED
                None,          # P_ROWS_DELETED
                None,          # P_FILES_LOADED
                ''SUCCESS''      # P_JOB_STATUS
            )
            
            log.info(f"[sp_refresh_lv] Audit updated to SUCCESS for audit_id={audit_id}")
        
        return f"SUCCESS: {lv_table} rebuilt with {row_count} active records"
        
    except Exception as exc:
        error_msg = f"ERROR: Failed to rebuild {lv_table}: {exc}"
        log.error(f"[sp_refresh_lv] {error_msg}")
        
        # AUDIT END - Failure - Call audit SP with FULLY QUALIFIED NAME
        if audit_id:
            error_escaped = str(exc).replace("''", "''''")[:16777216]
            session.call(
                ''DB_MAIN_CONSUMPTION_DEV.ACN_METADATA_CONFIG.SP_AUDIT_LOG_FAILURE'',
                audit_id,
                error_escaped
            )
            log.info(f"[sp_refresh_lv] Audit updated to FAILED for audit_id={audit_id}")
        
        return error_msg
';
+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++