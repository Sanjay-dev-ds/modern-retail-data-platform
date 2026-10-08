-- Reconciliation: every web purchase event must have an online order in the POS system.
-- Warn only: the two sources land on different schedules (DMS vs Firehose), so a purchase can
-- briefly arrive before its order; a persistent result is a real integration problem.
{{ config(severity='warn') }}

select s.session_id, s.order_id
from {{ ref('fct_sessions') }} s
left join {{ ref('stg_pos__transactions') }} t
    on t.transaction_id = s.order_id and t.channel = 'online'
where s.purchased
  and t.transaction_id is null
  and s.session_start < dateadd(hour, -1, current_timestamp())
