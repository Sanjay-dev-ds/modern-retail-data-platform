-- Sale lines, current state: the latest CDC version per (transaction_id, line_no).
-- Grain: one product on one sale.
select *
from {{ ref('stg_pos__transaction_lines_cdc') }}
qualify row_number() over (partition by transaction_id, line_no order by _dms_commit_ts desc, _file desc) = 1
