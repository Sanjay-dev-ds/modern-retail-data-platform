{{
    config(
        materialized='incremental',
        unique_key=['transaction_id', 'line_no'],
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

-- Sales fact. Grain: one product on one transaction (the line).
-- Incremental: reprocess every transaction whose header OR lines were loaded since the last run
-- (minus a lookback). A void/return only updates the header, so header changes must re-merge
-- that transaction's lines. Hard deletes stay as rows with is_deleted = true (soft delete).

with headers as (
    select * from {{ ref('stg_pos__transactions') }}
),

lines as (
    select * from {{ ref('stg_pos__transaction_lines') }}
),

{% if is_incremental() %}
watermark as (
    select dateadd(hour, -{{ var('sales_lookback_hours') }}, max(_loaded_at)) as since from {{ this }}
),

changed as (
    select transaction_id from headers where _loaded_at > (select since from watermark)
    union
    select transaction_id from lines where _loaded_at > (select since from watermark)
),
{% endif %}

joined as (
    select
        l.transaction_id,
        l.line_no,
        h.txn_ts,
        h.txn_ts::date                              as txn_date,
        h.store_id,
        h.customer_id,
        h.channel,
        h.status,
        l.sku,
        l.quantity,
        l.unit_price,
        l.discount_amount,
        l.promo_code,
        l.quantity * l.unit_price                   as gross_amount,
        l.quantity * l.unit_price - l.discount_amount as net_amount,
        coalesce(h.is_deleted, false) or l.is_deleted as is_deleted,
        greatest(l._loaded_at, coalesce(h._loaded_at, l._loaded_at)) as _loaded_at
    from lines l
    left join headers h on h.transaction_id = l.transaction_id
    {% if is_incremental() %}
    where l.transaction_id in (select transaction_id from changed)
    {% endif %}
)

select
    j.*,
    -- Point-in-time dimension keys (the version valid at the time of the sale).
    p.product_sk,
    c.customer_sk,
    s.store_sk
from joined j
left join {{ ref('dim_product') }} p
    on p.sku = j.sku
   and j.txn_date >= p.valid_from
   and (j.txn_date < p.valid_to or p.valid_to is null)
left join {{ ref('dim_customer') }} c
    on c.customer_id = j.customer_id
   and j.txn_ts >= c.valid_from
   and (j.txn_ts < c.valid_to or c.valid_to is null)
left join {{ ref('dim_store') }} s
    on s.store_id = j.store_id
   and j.txn_ts >= s.valid_from
   and (j.txn_ts < s.valid_to or s.valid_to is null)
