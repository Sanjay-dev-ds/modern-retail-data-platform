-- Daily sales by store and channel, for BI. Built from the line fact (no payment join).
select
    f.txn_date,
    f.store_id,
    s.store_name,
    s.region,
    f.channel,
    count(distinct iff(f.status = 'completed', f.transaction_id, null))  as completed_orders,
    sum(iff(f.status = 'completed', f.quantity, 0))                     as units_sold,
    sum(iff(f.status = 'completed', f.net_amount, 0))                   as net_revenue,
    sum(iff(f.status = 'completed', f.discount_amount, 0))              as discounts,
    count(distinct iff(f.status = 'voided', f.transaction_id, null))     as voided_orders,
    count(distinct iff(f.status = 'returned', f.transaction_id, null))   as returned_orders,
    sum(iff(f.status = 'returned', f.net_amount, 0))                    as returned_amount
from {{ ref('fct_sales_lines') }} f
left join {{ ref('dim_store') }} s
    on s.store_id = f.store_id and s.is_current
where not f.is_deleted
group by all
