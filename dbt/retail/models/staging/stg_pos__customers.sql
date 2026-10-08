-- Current state of each customer: the latest CDC version per key.
select *
from {{ ref('stg_pos__customers_cdc') }}
qualify row_number() over (partition by customer_id order by _dms_commit_ts desc, _file desc) = 1
