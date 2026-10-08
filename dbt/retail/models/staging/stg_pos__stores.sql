-- Current state of each store: the latest CDC version per key.
select *
from {{ ref('stg_pos__stores_cdc') }}
qualify row_number() over (partition by store_id order by _dms_commit_ts desc, _file desc) = 1
