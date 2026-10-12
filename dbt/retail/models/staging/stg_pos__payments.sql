-- Tenders, current state: the latest CDC version per payment_id.
-- Grain: one payment or refund (split tender = several rows per sale).
select *
from {{ ref('stg_pos__payments_cdc') }}
qualify row_number() over (partition by payment_id order by _dms_commit_ts desc, _file desc) = 1
