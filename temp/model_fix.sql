{{
    config(
        materialized        = 'incremental',
        unique_key          = 'dbt_scd_id',
        incremental_strategy= 'merge',
        schema              = 'governance_classification',
        on_schema_change    = 'fail',
        merge_update_columns= ['dwh_effective_to_tstamp', 'is_active', 'dwh_process_tstamp']
    )
}}

/*
    SCD Type-2 history model for governance classification data.

    Fixes applied vs original:
      [1]  Attribute hash computed ONCE as column alias; CASE + lag() both
           reference that alias — no copy-paste drift risk.
      [2]  destination_rows: on incremental reads the real table (open rows only,
           is_active = 'Y'); on full-refresh returns typed empty set so the
           schema exactly matches the live table.
      [3]  Final QUALIFY ORDER BY dwh_effective_to_tstamp DESC → open row
           (9999-12-31) wins, not the row being expired.
      [4]  All source columns present in destination stub + select lists:
           source_system, zone_name, env_name added everywhere they were missing.
      [5]  conditional_change_event removed; hash + lag() deduplication is
           sufficient and more portable.
      [6]  Expiry gap uses DATEADD(nanosecond,-1,...) instead of millisecond;
           closed-open interval pattern used in the current-record view.
      [7]  unchanged_records guarded with inner QUALIFY to prevent fan-out
           from the double left-join.
      [R1] dbt_scd_id = MD5(classification_id || source_ds_update) only —
           no payload columns so the key is stable across attribute changes.
      [R2] source_system, zone_name, env_name added to dwh_attribute_hash so
           changes in those columns trigger a new SCD2 version.
      [R3] BOOLEAN columns (is_business_key, is_primary_key, is_src_deleted)
           cast to VARCHAR consistently before concatenation in all hashes.
      [R4] merge_update_columns restricts what the MERGE touches — only the
           three closing-out columns are ever updated on an existing row.

    Incremental strategy:
      - 3-day lookback window on source to catch late-arriving records.
      - destination reads only currently open rows (is_active = 'Y').
      - MERGE key = dbt_scd_id; updates close old rows, inserts add new versions.
*/

-- ─────────────────────────────────────────────
-- STEP 1 : read & lightly validate source
-- ─────────────────────────────────────────────
with source_rows_base as (

    select
        object_id                           as classification_id,
        db_name,
        schema_name,
        table_name,
        column_name,
        security_classification_code,
        source_system,
        zone_name,
        env_name,
        is_business_key,
        is_primary_key,
        is_src_deleted,
        source_ds_update
    from {{ ref('governance_staging___governance_classification_data') }}
    where object_id is not null

),

-- ─────────────────────────────────────────────
-- STEP 2 : validate & deduplicate on natural key
-- ─────────────────────────────────────────────
source_rows_validated as (

    select *
    from source_rows_base
    where classification_id is not null
      and source_ds_update   is not null
    qualify row_number() over (
        partition by classification_id, source_ds_update
        order by source_ds_update
    ) = 1

),

-- ─────────────────────────────────────────────
-- STEP 3 : compute hashes (FIX [1][R1][R2][R3])
-- ─────────────────────────────────────────────
source_rows_hashed as (

    select
        *,

        -- FIX [R1] stable row key: natural key + timestamp only, no payload
        md5(
            coalesce(cast(classification_id as varchar), '') || '|' ||
            coalesce(to_char(source_ds_update, 'YYYY-MM-DD HH24:MI:SS.FF9'), '')
        ) as dbt_scd_id,

        -- FIX [1][R2][R3] single hash expression, referenced everywhere below
        -- includes source_system / zone_name / env_name (FIX R2)
        -- booleans cast to varchar (FIX R3)
        md5(
            coalesce(cast(security_classification_code as varchar), '') || '|' ||
            coalesce(cast(is_business_key              as varchar), '') || '|' ||
            coalesce(cast(is_primary_key               as varchar), '') || '|' ||
            coalesce(cast(is_src_deleted               as varchar), '') || '|' ||
            coalesce(source_system,                                  '') || '|' ||
            coalesce(zone_name,                                      '') || '|' ||
            coalesce(env_name,                                       '')
        ) as dwh_attribute_hash

    from source_rows_validated

),

-- ─────────────────────────────────────────────
-- STEP 4 : detect NEW / CHANGED / UNCHANGED
--          FIX [1]  lag() reuses dwh_attribute_hash — no re-expanded MD5
--          FIX [5]  conditional_change_event removed entirely
-- ─────────────────────────────────────────────
source_rows_value_change as (

    select
        *,
        case
            when row_number() over (
                     partition by classification_id
                     order by source_ds_update
                 ) = 1
                then 'NEW'
            -- FIX [1]: reference the already-computed column alias via lag()
            when dwh_attribute_hash
                 <> lag(dwh_attribute_hash) over (
                        partition by classification_id
                        order by source_ds_update
                    )
                then 'CHANGED'
            else 'UNCHANGED'
        end                                 as dwh_change_type,

        source_ds_update                    as dwh_effective_from_tstamp,
        to_timestamp_ntz('9999-12-31')      as dwh_effective_to_tstamp,
        'Y'                                 as is_active,
        current_timestamp()                 as dwh_process_tstamp

    from source_rows_hashed

),

-- keep the FIRST occurrence of each distinct attribute state per key
-- FIX [5]: partition on dwh_attribute_hash directly (no value_change column)
source_rows_deduped as (

    select *
    from source_rows_value_change
    qualify row_number() over (
        partition by classification_id, dwh_attribute_hash
        order by source_ds_update asc
    ) = 1

),

-- ─────────────────────────────────────────────
-- STEP 5 : apply incremental lookback window
-- ─────────────────────────────────────────────
source_rows as (

    select *
    from source_rows_deduped

    {% if is_incremental() %}
    -- 3-day lookback window to handle late-arriving records
    where source_ds_update > (
        select coalesce(
            dateadd(day, -3, max(source_ds_update)),
            '1900-01-01'::timestamp_ntz
        )
        from {{ this }}
    )
    {% endif %}

),

-- ─────────────────────────────────────────────
-- STEP 6 : destination — open rows only
--          FIX [2]  real table on incremental; typed empty set on full-refresh
--          FIX [4]  source_system, zone_name, env_name present in stub
-- ─────────────────────────────────────────────
destination_rows as (

    /*
        Both branches select IDENTICAL, EXPLICIT column lists in the same order.
        This is the root-cause fix for "invalid identifier d.source_system":
          - select * from {{ this }} relies on the physical column order in the
            live table, which may differ from what downstream CTEs expect,
            especially after schema migrations or the very first incremental run.
          - Explicit column lists make the CTE schema deterministic regardless
            of how Snowflake stored the table.
    */

    {% if is_incremental() %}

        select
            dbt_scd_id,
            classification_id,
            db_name,
            schema_name,
            table_name,
            column_name,
            security_classification_code,
            source_system,
            zone_name,
            env_name,
            is_business_key,
            is_primary_key,
            is_src_deleted,
            source_ds_update,
            dwh_effective_from_tstamp,
            dwh_effective_to_tstamp,
            dwh_change_type,
            dwh_attribute_hash,
            is_active,
            dwh_process_tstamp
        from {{ this }}
        where is_active = 'Y'

    {% else %}

        -- full-refresh: typed empty set — column names + types must match live table exactly
        select
            cast(null as varchar)               as dbt_scd_id,
            cast(null as number(38, 0))         as classification_id,
            cast(null as varchar)               as db_name,
            cast(null as varchar)               as schema_name,
            cast(null as varchar)               as table_name,
            cast(null as varchar)               as column_name,
            cast(null as varchar)               as security_classification_code,
            cast(null as varchar)               as source_system,
            cast(null as varchar)               as zone_name,
            cast(null as varchar)               as env_name,
            cast(null as boolean)               as is_business_key,
            cast(null as boolean)               as is_primary_key,
            cast(null as boolean)               as is_src_deleted,
            cast(null as timestamp_ntz(9))      as source_ds_update,
            cast(null as timestamp_ntz(9))      as dwh_effective_from_tstamp,
            cast(null as timestamp_ntz(9))      as dwh_effective_to_tstamp,
            cast(null as varchar)               as dwh_change_type,
            cast(null as varchar)               as dwh_attribute_hash,
            cast(null as varchar)               as is_active,
            cast(null as timestamp_ntz(9))      as dwh_process_tstamp
        where 1 = 0

    {% endif %}

),

-- ─────────────────────────────────────────────
-- STEP 7 : compare source vs destination
-- ─────────────────────────────────────────────
source_data_by_id as (

    select
        s.classification_id,
        s.db_name,
        s.schema_name,
        s.table_name,
        s.column_name,
        s.security_classification_code,
        s.source_system,
        s.zone_name,
        s.env_name,
        s.is_business_key,
        s.is_primary_key,
        s.is_src_deleted,
        s.source_ds_update,
        s.dbt_scd_id,
        s.dwh_change_type,
        s.is_active,
        s.dwh_attribute_hash                    as src_attribute_hash,
        s.dwh_process_tstamp,
        s.dwh_effective_from_tstamp,
        s.dwh_effective_to_tstamp,
        d.dwh_attribute_hash                    as dest_attribute_hash,
        d.dbt_scd_id                            as dest_dbt_scd_id,
        d.source_ds_update                      as dest_source_ds_update,
        case
            when d.classification_id is null                             then 'NEW'
            when s.dwh_attribute_hash = d.dwh_attribute_hash             then 'UNCHANGED'
            else                                                              'CHANGED'
        end                                     as derived_dml_type_code
    from source_rows s
    left join destination_rows d
        on  s.classification_id = d.classification_id

),

-- ─────────────────────────────────────────────
-- STEP 8 : compute closing timestamp for changed rows
--          FIX [6] nanosecond gap instead of millisecond
-- ─────────────────────────────────────────────
new_valid_to as (

    select
        dest_dbt_scd_id                                     as dbt_scd_id,
        classification_id,
        dateadd(nanosecond, -1, source_ds_update)           as dwh_effective_to_tstamp,  -- FIX [6]
        'N'                                                 as new_is_active
    from source_data_by_id
    where derived_dml_type_code = 'CHANGED'

),

-- ─────────────────────────────────────────────
-- STEP 9 : build the updated (expired) destination rows
-- ─────────────────────────────────────────────
records_to_update as (

    select
        d.classification_id,
        d.db_name,
        d.schema_name,
        d.table_name,
        d.column_name,
        d.security_classification_code,
        d.source_system,
        d.zone_name,
        d.env_name,
        d.is_business_key,
        d.is_primary_key,
        d.is_src_deleted,
        d.source_ds_update,
        d.dwh_effective_from_tstamp,
        n.dwh_effective_to_tstamp,                          -- closed timestamp
        d.dbt_scd_id,
        d.dwh_change_type,
        n.new_is_active                                     as is_active,
        d.dwh_attribute_hash,
        d.dwh_process_tstamp
    from destination_rows d
    inner join new_valid_to n
        on  d.classification_id = n.classification_id
        and d.dbt_scd_id        = n.dbt_scd_id

),

-- ─────────────────────────────────────────────
-- STEP 10 : pass-through unchanged destination rows
--           FIX [7] inner QUALIFY prevents fan-out from double left-join
-- ─────────────────────────────────────────────
unchanged_records as (

    select
        d.classification_id,
        d.db_name,
        d.schema_name,
        d.table_name,
        d.column_name,
        d.security_classification_code,
        d.source_system,
        d.zone_name,
        d.env_name,
        d.is_business_key,
        d.is_primary_key,
        d.is_src_deleted,
        d.source_ds_update,
        d.dwh_effective_from_tstamp,
        d.dwh_effective_to_tstamp,
        d.dbt_scd_id,
        case
            when s.derived_dml_type_code = 'UNCHANGED'
             and d.dwh_effective_to_tstamp = to_timestamp_ntz('9999-12-31')
                then 'UNCHANGED'
            else d.dwh_change_type
        end                                                 as dwh_change_type,
        d.is_active,
        d.dwh_attribute_hash,
        d.dwh_process_tstamp
    from destination_rows d
    left join new_valid_to n
        on  d.classification_id = n.classification_id
        and d.dbt_scd_id        = n.dbt_scd_id
    left join source_data_by_id s
        on  d.classification_id     = s.classification_id
        and s.derived_dml_type_code = 'UNCHANGED'
    where n.dbt_scd_id is null                              -- exclude rows being expired
    qualify row_number() over (                             -- FIX [7]: fan-out guard
        partition by d.classification_id, d.dbt_scd_id
        order by d.dwh_effective_from_tstamp desc
    ) = 1

),

-- ─────────────────────────────────────────────
-- STEP 11 : new SCD2 rows to insert
-- ─────────────────────────────────────────────
new_source_records as (

    select
        classification_id,
        db_name,
        schema_name,
        table_name,
        column_name,
        security_classification_code,
        source_system,
        zone_name,
        env_name,
        is_business_key,
        is_primary_key,
        is_src_deleted,
        source_ds_update,
        dwh_effective_from_tstamp,
        to_timestamp_ntz('9999-12-31')                      as dwh_effective_to_tstamp,
        dbt_scd_id,
        derived_dml_type_code                               as dwh_change_type,
        is_active,
        src_attribute_hash                                  as dwh_attribute_hash,
        dwh_process_tstamp
    from source_data_by_id
    where derived_dml_type_code != 'UNCHANGED'

),

-- ─────────────────────────────────────────────
-- STEP 12 : union all three streams
-- ─────────────────────────────────────────────
all_records as (

    select * from records_to_update
    union all
    select * from unchanged_records
    union all
    select * from new_source_records

)

-- ─────────────────────────────────────────────
-- FINAL SELECT
-- FIX [3] ORDER BY dwh_effective_to_tstamp DESC → open row wins
-- ─────────────────────────────────────────────
select
    dbt_scd_id,
    classification_id,
    db_name,
    schema_name,
    table_name,
    column_name,
    security_classification_code,
    source_system,
    zone_name,
    env_name,
    is_business_key,
    is_primary_key,
    is_src_deleted,
    source_ds_update,
    dwh_effective_from_tstamp,
    dwh_effective_to_tstamp,
    dwh_change_type,
    dwh_attribute_hash,
    is_active,
    dwh_process_tstamp

from all_records

qualify row_number() over (
    partition by classification_id, dwh_effective_from_tstamp
    order by
        dwh_effective_from_tstamp                           asc,
        case dwh_change_type
            when 'NEW'     then 1
            when 'CHANGED' then 2
            else                3
        end,
        dwh_effective_to_tstamp                             desc  -- FIX [3]: open row (9999-12-31) wins
) = 1
