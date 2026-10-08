-- Order headers, current state. A CDC batch can hold several versions of one transaction
-- (insert, then void); keep the latest. Deleted rows (Op = 'D') carry only the key.
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
    record:"Op"::string = 'D'           as is_deleted,
    {{ to_ts('record:"_dms_commit_ts"') }} as _dms_commit_ts,
    _file,
    _loaded_at
from {{ source('raw', 'pos_transactions') }}
qualify row_number() over (partition by transaction_id order by _dms_commit_ts desc, _file desc) = 1
