-- Reconciliation: the tenders of a sale must add up to its total. A small share is planted to
-- mismatch (payment_mismatch defect), so this warns rather than fails.
{{ config(severity='warn') }}

select
    t.transaction_id,
    t.total_amount,
    sum(p.amount) as paid_amount
from {{ ref('stg_pos__transactions') }} t
join {{ ref('stg_pos__payments') }} p on p.transaction_id = t.transaction_id
where not t.is_deleted and not p.is_deleted
group by t.transaction_id, t.total_amount
having abs(t.total_amount - sum(p.amount)) > 0.009
