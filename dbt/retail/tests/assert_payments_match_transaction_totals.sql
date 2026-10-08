-- Reconciliation: the tenders of a sale must add up to its total. A small share is planted to
-- mismatch (payment_mismatch defect), so this warns rather than fails. Single-model test on
-- fct_payments (it carries the header total), so it runs right after fct_payments.
{{ config(severity='warn') }}

select
    transaction_id,
    max(transaction_total) as transaction_total,
    sum(amount)            as paid_amount
from {{ ref('fct_payments') }}
where not is_deleted
group by transaction_id
having abs(max(transaction_total) - sum(amount)) > 0.009
