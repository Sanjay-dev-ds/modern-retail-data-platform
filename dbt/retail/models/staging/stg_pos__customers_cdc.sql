-- Every replicated version of every customer. Feeds dim_customer (SCD2).
select
    record:"customer_id"::int           as customer_id,
    record:"email"::string              as email,
    record:"phone"::string              as phone,
    record:"loyalty_tier"::string       as loyalty_tier,
    record:"home_store_id"::int         as home_store_id,
    {{ to_ts('record:"signup_at"') }}   as signup_at,
    {{ to_ts('record:"updated_at"') }}  as updated_at,
    record:"Op"::string = 'D'           as is_deleted,
    {{ to_ts('record:"_dms_commit_ts"') }} as _dms_commit_ts,
    _file,
    _loaded_at
from {{ source('raw', 'pos_customers') }}
