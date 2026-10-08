{{
    config(
        materialized='incremental',
        unique_key='session_id',
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

-- Web session fact. Grain: one session. Late events (a phone that was offline) arrive hours
-- after event_ts, so the watermark uses _loaded_at (when Snowflake received them), and every
-- session touched since then is re-aggregated from ALL its events.

with events as (
    select * from {{ ref('stg_clickstream__events') }}
    {% if is_incremental() %}
    where session_id in (
        select session_id
        from {{ ref('stg_clickstream__events') }}
        where _loaded_at > (
            select dateadd(hour, -{{ var('clickstream_lookback_hours') }}, max(_loaded_at)) from {{ this }}
        )
    )
    {% endif %}
),

sessions as (
    select
        session_id,
        any_value(anonymous_id)                             as anonymous_id,
        max(customer_id)                                    as customer_id,   -- set after login
        min(event_ts)                                       as session_start,
        max(event_ts)                                       as session_end,
        datediff('second', min(event_ts), max(event_ts))    as duration_seconds,
        count(*)                                            as events,
        min_by(device, event_ts)                            as device,
        min_by(utm_source, event_ts)                        as utm_source,
        min_by(utm_medium, event_ts)                        as utm_medium,
        min_by(utm_campaign, event_ts)                      as utm_campaign,
        boolor_agg(event_type = 'product_view')             as viewed_product,
        boolor_agg(event_type = 'add_to_cart')              as added_to_cart,
        boolor_agg(event_type = 'checkout_started')         as started_checkout,
        boolor_agg(event_type = 'purchase')                 as purchased,
        max(order_id)                                       as order_id,      -- = pos transaction_id
        max(_loaded_at)                                     as _loaded_at
    from events
    group by session_id
)

select
    s.*,
    -- Cross-source reconciliation: does the web order exist as an online POS transaction?
    -- (evaluated when the session is (re)merged)
    s.order_id is null or t.transaction_id is not null  as pos_order_found
from sessions s
left join {{ ref('stg_pos__transactions') }} t
    on t.transaction_id = s.order_id and t.channel = 'online'
