-- Reconciliation: a completed sale's tenders add up to its total; a voided or returned sale is
-- fully refunded, so its tenders net to 0. A small share is planted to mismatch
-- (payment_mismatch defect), so this warns rather than fails. Single-model test on fct_payments
-- (it carries the header total and status), so it runs right after fct_payments.
{{ config(severity='warn') }}

select
    transaction_id,
    max(status)            as status,
    max(transaction_total) as transaction_total,
    sum(amount)            as net_paid
from {{ ref('fct_payments') }}
where not is_deleted
group by transaction_id
having abs(iff(max(status) = 'completed', max(transaction_total), 0) - sum(amount)) > 0.009
