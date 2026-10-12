-- Payment reconciliation: does the money received match each sale?
--
-- Expected net payment per sale:
--   * completed          -> the payments add up to the sale's total_amount
--   * voided or returned -> every payment has a matching refund, so they net to 0
--
-- Each row returned is a sale that does not reconcile (gap > 0.009, allowing for rounding).
-- Deleted sales are ignored.
--
-- Severity is `warn`: so failures are expected and should be reported, not block
-- the pipeline.
--
-- The test reads only fct_payments, which already carries each sale's total and status, so
-- Cosmos runs it straight after that model is built.
{{ config(severity='warn') }}

select
    transaction_id,
    max(status)            as status,
    max(transaction_total) as transaction_total,
    sum(amount)            as net_paid
from {{ ref('fct_payments') }}
where not is_deleted
group by transaction_id
-- Keep only the sales that don't reconcile: the absolute difference between the expected
-- net payment (the sale total if completed, 0 if voided or returned) and the amount actually
-- paid (net_paid, refunds included) is greater than 0.009, i.e. off by at least one cent.
having abs(iff(max(status) = 'completed', max(transaction_total), 0) - sum(amount)) > 0.009
