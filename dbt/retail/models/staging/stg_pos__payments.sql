-- Tenders, current state. Grain: one payment (split tender = several rows per transaction).
select
    record:"payment_id"::string         as payment_id,
    record:"transaction_id"::string     as transaction_id,
    record:"method"::string             as method,
    record:"amount"::number(12, 2)      as amount,
    {{ to_ts('record:"created_at"') }}  as created_at,
    record:"Op"::string = 'D'           as is_deleted,
    {{ to_ts('record:"_dms_commit_ts"') }} as _dms_commit_ts,
    _file,
    _loaded_at
from {{ source('raw', 'pos_payments') }}
qualify row_number() over (partition by payment_id order by _dms_commit_ts desc, _file desc) = 1
