-- Clickstream events, one row per event_id. Firehose delivery is at-least-once, so the same
-- event can arrive twice: keep the first copy loaded.
select
    record:"event_id"::string           as event_id,
    record:"event_type"::string         as event_type,
    {{ to_ts('record:"event_ts"') }}    as event_ts,
    record:"session_id"::string         as session_id,
    record:"anonymous_id"::string       as anonymous_id,
    record:"customer_id"::int           as customer_id,
    record:"page_url"::string           as page_url,
    record:"sku"::string                as sku,
    record:"quantity"::int              as quantity,
    record:"order_id"::string           as order_id,
    record:"device"::string             as device,
    record:"utm_source"::string         as utm_source,
    record:"utm_medium"::string         as utm_medium,
    record:"utm_campaign"::string       as utm_campaign,
    record:"schema_version"::int        as schema_version,
    _file,
    _loaded_at
from {{ source('raw', 'clickstream_events') }}
qualify row_number() over (partition by event_id order by _loaded_at, _file) = 1
