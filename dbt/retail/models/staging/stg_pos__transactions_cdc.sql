-- Every replicated version of every sale header (insert, then void/return updates, deletes).
select
    record:"transaction_id"::string     as transaction_id,
    record:"store_id"::int              as store_id,
    record:"customer_id"::int           as customer_id,
    record:"channel"::string            as channel,
    {{ to_ts('record:"txn_ts"') }}      as txn_ts,
    record:"status"::string             as status,
    record:"total_amount"::number(12, 2) as total_amount,
    record:"currency"::string           as currency,
    {{ to_ts('record:"updated_at"') }}  as updated_at,
    {{ cdc_columns() }}
from {{ source('raw', 'pos_transactions') }}
