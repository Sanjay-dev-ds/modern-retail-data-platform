-- Sale headers, current state: the latest CDC version per transaction_id.
-- Deleted sales (cdc_operation = DELETE) carry only the key.
select *
from {{ ref('stg_pos__transactions_cdc') }}
qualify row_number() over (partition by transaction_id order by _dms_commit_ts desc, _file desc) = 1
