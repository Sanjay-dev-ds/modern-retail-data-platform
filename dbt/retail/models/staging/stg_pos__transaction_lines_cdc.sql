-- Every replicated version of every sale line (lines are inserted, and deleted with their sale).
select
    record:"transaction_id"::string     as transaction_id,
    record:"line_no"::int               as line_no,
    record:"sku"::string                as sku,
    record:"quantity"::int              as quantity,
    record:"unit_price"::number(10, 2)  as unit_price,
    record:"discount_amount"::number(10, 2) as discount_amount,
    record:"promo_code"::string         as promo_code,
    {{ cdc_columns() }}
from {{ source('raw', 'pos_transaction_lines') }}
