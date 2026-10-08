{{
    config(
        materialized='incremental',
        unique_key=['store_id', 'version_ts'],
        incremental_strategy='merge'
    )
}}

-- SCD2 store dimension from the CDC history: a new version only when a tracked attribute
-- changes. store_sk is a sequential integer assigned once per version (macros/surrogate_key.sql).
-- Incremental: for stores with new CDC rows, rebuild their version chain and merge - existing
-- versions keep their key and get valid_to/is_current updated, new versions get new keys.
-- The first version is open from 1900-01-01 (history before the DMS full load is unknown).

with changed_stores as (
    select distinct store_id
    from {{ ref('stg_pos__stores_cdc') }}
    {% if is_incremental() %}
    where _loaded_at > (select max(_loaded_at) from {{ this }})
    {% endif %}
),

versions as (
    select
        *,
        md5(concat_ws('|', store_name, region, format, open_date)) as attr_hash
    from {{ ref('stg_pos__stores_cdc') }}
    where not is_deleted
      and store_id in (select store_id from changed_stores)
),

changes as (
    select *
    from versions
    qualify lag(attr_hash) over (partition by store_id order by _dms_commit_ts) is distinct from attr_hash
),

scd2 as (
    select
        store_id,
        store_name,
        region,
        format,
        open_date,
        _dms_commit_ts                                                           as version_ts,
        iff(
            row_number() over (partition by store_id order by _dms_commit_ts) = 1,
            '1900-01-01'::timestamp_ntz,
            _dms_commit_ts
        )                                                                        as valid_from,
        lead(_dms_commit_ts) over (partition by store_id order by _dms_commit_ts) as valid_to,
        _loaded_at
    from changes
),

keyed as (
    select
        s.*,
        {% if is_incremental() %} t.store_sk {% else %} null::number {% endif %} as existing_sk
    from scd2 s
    {% if is_incremental() %}
    left join {{ this }} t on t.store_id = s.store_id and t.version_ts = s.version_ts
    {% endif %}
)

select
    {{ next_surrogate_key('store_sk', 'store_id, version_ts') }} as store_sk,
    store_id,
    store_name,
    region,
    format,
    open_date,
    version_ts,
    valid_from,
    valid_to,
    valid_to is null                                            as is_current,
    _loaded_at
from keyed

union all

-- Unknown member: facts point here instead of holding a null key.
select -1, -1, 'Unknown', 'unknown', 'unknown', null,
       '1900-01-01'::timestamp_ntz, '1900-01-01'::timestamp_ntz, null, true, '1900-01-01'::timestamp_ltz
