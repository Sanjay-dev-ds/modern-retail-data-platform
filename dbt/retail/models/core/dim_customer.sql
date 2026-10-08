-- SCD2 customer dimension from the CDC history (loyalty tier upgrades, email fixes, ...).
-- Same pattern as dim_store: new version only on an attribute change, first version open-ended.
with versions as (
    select
        *,
        md5(concat_ws('|', coalesce(email, ''), coalesce(phone, ''), loyalty_tier, home_store_id)) as attr_hash
    from {{ ref('stg_pos__customers_cdc') }}
    where not is_deleted
),

changes as (
    select *
    from versions
    qualify lag(attr_hash) over (partition by customer_id order by _dms_commit_ts) is distinct from attr_hash
)

select
    {{ dbt_utils.generate_surrogate_key(['customer_id', '_dms_commit_ts']) }} as customer_sk,
    customer_id,
    email,
    phone,
    loyalty_tier,
    home_store_id,
    signup_at,
    iff(
        row_number() over (partition by customer_id order by _dms_commit_ts) = 1,
        '1900-01-01'::timestamp_ntz,
        _dms_commit_ts
    )                                                                          as valid_from,
    lead(_dms_commit_ts) over (partition by customer_id order by _dms_commit_ts) as valid_to,
    valid_to is null                                                           as is_current
from changes
