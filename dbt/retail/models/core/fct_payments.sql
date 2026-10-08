{{
    config(
        materialized='incremental',
        unique_key='payment_id',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

-- Payment fact. Grain: one tender. Kept separate from fct_sales_lines: joining payments to
-- lines fans out (a 3-line sale paid in 2 tenders would become 6 rows and double count).

with payments as (
    select * from {{ ref('stg_pos__payments') }}
),

headers as (
    select * from {{ ref('stg_pos__transactions') }}
)

select
    p.payment_id,
    p.transaction_id,
    p.method,
    p.amount,
    h.total_amount                                  as transaction_total,
    h.txn_ts,
    h.txn_ts::date                                  as txn_date,
    h.store_id,
    h.channel,
    h.status,
    coalesce(h.is_deleted, false) or p.is_deleted   as is_deleted,
    greatest(p._loaded_at, coalesce(h._loaded_at, p._loaded_at)) as _loaded_at
from payments p
left join headers h on h.transaction_id = p.transaction_id
{% if is_incremental() %}
where p._loaded_at > (select dateadd(hour, -{{ var('sales_lookback_hours') }}, max(_loaded_at)) from {{ this }})
   or h._loaded_at > (select dateadd(hour, -{{ var('sales_lookback_hours') }}, max(_loaded_at)) from {{ this }})
{% endif %}
