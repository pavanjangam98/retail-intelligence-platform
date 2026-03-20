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

    COUNT BUG FIX (is_src_deleted N inflation  source N=26 → history N=68):
    ────────────────────────────────────────────────────────────────────────
    Old code in source_rows_deduped:
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY classification_id, dwh_attribute_hash   ← BUG
            ORDER BY source_ds_update ASC
        ) = 1

    This partitions GLOBALLY on the hash value.  When a table flips
    is_src_deleted  N → Y → N  both N rows share the same attribute hash.
    The QUALIFY discards the SECOND N, keeping only the earliest one.
    But that second N was already an open row in destination_rows, so
    unchanged_records passed it through untouched.  The final union then
    contained BOTH the passed-through destination row AND a new_source_record
    insert for the same key, doubling every N that had ever appeared twice.

    Fix: filter source_rows_deduped to keep only rows where dwh_change_type
    IN ('NEW', 'CHANGED') — i.e. only the LEADING EDGE of each consecutive
    same-hash block.  This is strictly equivalent to conditional_change_event
    but portable and correct:
      • N → Y → N  produces three separate SCD2 versions  ✓
      • Repeated identical rows within one load are still collapsed  ✓
      • No global hash-collapse across non-consecutive time periods  ✓

    All prior fixes retained:
      [1]  Hash computed once; lag() references alias — no drift.
      [2]  destination_rows: explicit column list in BOTH branches.
      [3]  Final QUALIFY ORDER BY effective_to DESC — open row wins.
      [4]  source_system / zone_name / env_name in all select lists.
      [5]  conditional_change_event removed.
      [6]  Nanosecond expiry gap.
      [7]  unchanged_records fan-out QUALIFY guard.
      [R1] dbt_scd_id = stable natural key hash only.
      [R2] source_system / zone_name / env_name in attribute hash.
      [R3] BOOLEAN columns cast to VARCHAR in hashes.
      [R4] merge_update_columns restricts MERGE to closing columns only.
*/

-- ─────────────────────────────────────────────
-- STEP 1 : read source
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
-- STEP 2 : validate — drop nulls on mandatory fields;
--          deduplicate on (classification_id, source_ds_update)
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
-- STEP 3 : compute both hashes ONCE
--          [R1] dbt_scd_id  — natural key + timestamp only (no payload)
--          [R2] attribute hash includes source_system / zone_name / env_name
--          [R3] booleans cast to varchar before concat
-- ─────────────────────────────────────────────
source_rows_hashed as (

    select
        *,

        md5(
            coalesce(cast(classification_id as varchar), '') || '|' ||
            coalesce(to_char(source_ds_update, 'YYYY-MM-DD HH24:MI:SS.FF9'), '')
        )                                   as dbt_scd_id,

        md5(
            coalesce(cast(security_classification_code as varchar), '') || '|' ||
            coalesce(cast(is_business_key              as varchar), '') || '|' ||
            coalesce(cast(is_primary_key               as varchar), '') || '|' ||
            coalesce(cast(is_src_deleted               as varchar), '') || '|' ||
            coalesce(source_system,                                  '') || '|' ||
            coalesce(zone_name,                                      '') || '|' ||
            coalesce(env_name,                                       '')
        )                                   as dwh_attribute_hash

    from source_rows_validated

),

-- ─────────────────────────────────────────────
-- STEP 4 : tag each row NEW / CHANGED / UNCHANGED
--          [1] lag() references hash alias — no re-expanded MD5
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
            when dwh_attribute_hash <>
                 lag(dwh_attribute_hash) over (
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

-- ─────────────────────────────────────────────
-- STEP 5 : keep only the LEADING EDGE of each consecutive same-hash block
--
-- COUNT BUG FIX:
--   Keep rows where dwh_change_type IN ('NEW','CHANGED') only.
--   This suppresses repeated UNCHANGED rows within a single load batch
--   WITHOUT globally collapsing rows that share a hash across non-adjacent
--   time periods (e.g. N→Y→N — both N rows are kept as separate versions).
-- ─────────────────────────────────────────────
source_rows_deduped as (

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
        dbt_scd_id,
        dwh_attribute_hash,
        dwh_change_type,
        dwh_effective_from_tstamp,
        dwh_effective_to_tstamp,
        is_active,
        dwh_process_tstamp
    from source_rows_value_change
    where dwh_change_type in ('NEW', 'CHANGED')   -- leading edge of each change block only

),

-- ─────────────────────────────────────────────
-- STEP 6 : incremental lookback window
-- ─────────────────────────────────────────────
source_rows as (

    select *
    from source_rows_deduped

    {% if is_incremental() %}
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
-- STEP 7 : destination — currently open rows only
--          Explicit column list in BOTH branches — never SELECT *
--          This fixes "invalid identifier" when {{ this }} column order
--          differs from what downstream CTEs expect.
-- ─────────────────────────────────────────────
destination_rows as (

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
-- STEP 8 : compare source vs destination
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
            when d.classification_id is null                        then 'NEW'
            when s.dwh_attribute_hash = d.dwh_attribute_hash        then 'UNCHANGED'
            else                                                         'CHANGED'
        end                                     as derived_dml_type_code
    from source_rows s
    left join destination_rows d
        on s.classification_id = d.classification_id

),

-- ─────────────────────────────────────────────
-- STEP 9 : closing timestamp for changed rows  [6] nanosecond gap
-- ─────────────────────────────────────────────
new_valid_to as (

    select
        dest_dbt_scd_id                                         as dbt_scd_id,
        classification_id,
        dateadd(nanosecond, -1, source_ds_update)               as dwh_effective_to_tstamp,
        'N'                                                     as new_is_active
    from source_data_by_id
    where derived_dml_type_code = 'CHANGED'

),

-- ─────────────────────────────────────────────
-- STEP 10 : expired destination rows (MERGE will UPDATE these)
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
        n.dwh_effective_to_tstamp,
        d.dbt_scd_id,
        d.dwh_change_type,
        n.new_is_active                                         as is_active,
        d.dwh_attribute_hash,
        d.dwh_process_tstamp
    from destination_rows d
    inner join new_valid_to n
        on  d.classification_id = n.classification_id
        and d.dbt_scd_id        = n.dbt_scd_id

),

-- ─────────────────────────────────────────────
-- STEP 11 : pass-through unchanged destination rows
--           [7] QUALIFY guard prevents double left-join fan-out
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
        end                                                     as dwh_change_type,
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
    where n.dbt_scd_id is null
    qualify row_number() over (
        partition by d.classification_id, d.dbt_scd_id
        order by d.dwh_effective_from_tstamp desc
    ) = 1

),

-- ─────────────────────────────────────────────
-- STEP 12 : new SCD2 rows to insert
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
        to_timestamp_ntz('9999-12-31')                          as dwh_effective_to_tstamp,
        dbt_scd_id,
        derived_dml_type_code                                   as dwh_change_type,
        is_active,
        src_attribute_hash                                      as dwh_attribute_hash,
        dwh_process_tstamp
    from source_data_by_id
    where derived_dml_type_code != 'UNCHANGED'

),

-- ─────────────────────────────────────────────
-- STEP 13 : union all three streams
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
-- [3] ORDER BY effective_to DESC → open row (9999-12-31) always wins
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
        dwh_effective_from_tstamp                               asc,
        case dwh_change_type
            when 'NEW'     then 1
            when 'CHANGED' then 2
            else                3
        end,
        dwh_effective_to_tstamp                                 desc
) = 1
