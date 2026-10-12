-- Every replicated version of every tender, including refunds (negative amounts).
select
    record:"payment_id"::string         as payment_id,
    record:"transaction_id"::string     as transaction_id,
    record:"method"::string             as method,
    record:"amount"::number(12, 2)      as amount,
    {{ to_ts('record:"created_at"') }}  as created_at,
    {{ cdc_columns() }}
from {{ source('raw', 'pos_payments') }}
