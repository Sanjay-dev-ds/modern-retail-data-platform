{{
    config(
        materialized='incremental',
        unique_key=['customer_id', 'version_ts'],
        incremental_strategy='merge'
    )
}}

-- SCD2 customer dimension from the CDC history (loyalty tier upgrades, email fixes, ...).
-- Same pattern as dim_store: sequential customer_sk assigned once per version, incremental
-- merge that closes the previous version, first version open-ended, -1 = Unknown member.

with changed_customers as (
    select distinct customer_id
    from {{ ref('stg_pos__customers_cdc') }}
    {% if is_incremental() %}
    where _loaded_at > (select max(_loaded_at) from {{ this }})
    {% endif %}
),

versions as (
    select
        *,
        md5(concat_ws('|', coalesce(email, ''), coalesce(phone, ''), loyalty_tier, home_store_id)) as attr_hash
    from {{ ref('stg_pos__customers_cdc') }}
    where not is_deleted
      and customer_id in (select customer_id from changed_customers)
),

changes as (
    select *
    from versions
    qualify lag(attr_hash) over (partition by customer_id order by _dms_commit_ts) is distinct from attr_hash
),

scd2 as (
    select
        customer_id,
        email,
        phone,
        loyalty_tier,
        home_store_id,
        signup_at,
        _dms_commit_ts                                                              as version_ts,
        iff(
            row_number() over (partition by customer_id order by _dms_commit_ts) = 1,
            '1900-01-01'::timestamp_ntz,
            _dms_commit_ts
        )                                                                           as valid_from,
        lead(_dms_commit_ts) over (partition by customer_id order by _dms_commit_ts) as valid_to,
        _loaded_at
    from changes
),

keyed as (
    select
        s.*,
        {% if is_incremental() %} t.customer_sk {% else %} null::number {% endif %} as existing_sk
    from scd2 s
    {% if is_incremental() %}
    left join {{ this }} t on t.customer_id = s.customer_id and t.version_ts = s.version_ts
    {% endif %}
)

select
    {{ next_surrogate_key('customer_sk', 'customer_id, version_ts') }} as customer_sk,
    customer_id,
    email,
    phone,
    loyalty_tier,
    home_store_id,
    signup_at,
    version_ts,
    valid_from,
    valid_to,
    valid_to is null                                                  as is_current,
    _loaded_at
from keyed

union all

-- Unknown member: anonymous sales and unmatched customer_ids point here.
select -1, -1, null, null, 'unknown', -1, null,
       '1900-01-01'::timestamp_ntz, '1900-01-01'::timestamp_ntz, null, true, '1900-01-01'::timestamp_ltz
