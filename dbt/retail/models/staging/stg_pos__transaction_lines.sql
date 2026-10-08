-- Order lines, current state. Grain: one product on one transaction.
select
    record:"transaction_id"::string     as transaction_id,
    record:"line_no"::int               as line_no,
    record:"sku"::string                as sku,
    record:"quantity"::int              as quantity,
    record:"unit_price"::number(10, 2)  as unit_price,
    record:"discount_amount"::number(10, 2) as discount_amount,
    record:"promo_code"::string         as promo_code,
    record:"Op"::string = 'D'           as is_deleted,
    {{ to_ts('record:"_dms_commit_ts"') }} as _dms_commit_ts,
    _file,
    _loaded_at
from {{ source('raw', 'pos_transaction_lines') }}
qualify row_number() over (
    partition by transaction_id, line_no order by _dms_commit_ts desc, _file desc
) = 1
