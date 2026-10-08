-- SCD2 store dimension built from the CDC history: a new version only when a tracked attribute
-- changes. The first version is open from 1900-01-01, because history before the DMS full load
-- is unknown and backdated sales must still find their store.
with versions as (
    select
        *,
        md5(concat_ws('|', store_name, region, format, open_date)) as attr_hash
    from {{ ref('stg_pos__stores_cdc') }}
    where not is_deleted
),

changes as (
    select *
    from versions
    qualify lag(attr_hash) over (partition by store_id order by _dms_commit_ts) is distinct from attr_hash
)

select
    {{ dbt_utils.generate_surrogate_key(['store_id', '_dms_commit_ts']) }} as store_sk,
    store_id,
    store_name,
    region,
    format,
    open_date,
    iff(
        row_number() over (partition by store_id order by _dms_commit_ts) = 1,
        '1900-01-01'::timestamp_ntz,
        _dms_commit_ts
    )                                                                       as valid_from,
    lead(_dms_commit_ts) over (partition by store_id order by _dms_commit_ts) as valid_to,
    valid_to is null                                                        as is_current
from changes
