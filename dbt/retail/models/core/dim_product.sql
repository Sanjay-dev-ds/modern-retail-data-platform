{{
    config(
        materialized='incremental',
        unique_key=['sku', 'version_date'],
        incremental_strategy='merge'
    )
}}

-- SCD2 product dimension from the supplier's daily full snapshots: compare each day with the
-- previous one and open a new version only when an attribute changed (price, active flag, ...).
-- Sequential product_sk assigned once per version; -1 = Unknown member (orphan SKUs in sales).

with changed_skus as (
    select distinct sku
    from {{ ref('stg_catalog__products') }}
    {% if is_incremental() %}
    where _loaded_at > (select max(_loaded_at) from {{ this }})
    {% endif %}
),

snapshots as (
    select
        *,
        md5(concat_ws('|', product_name, brand, category, subcategory, unit_cost, list_price, is_active)) as attr_hash
    from {{ ref('stg_catalog__products') }}
    where sku in (select sku from changed_skus)
),

changes as (
    select *
    from snapshots
    qualify lag(attr_hash) over (partition by sku order by snapshot_date) is distinct from attr_hash
),

scd2 as (
    select
        sku,
        product_name,
        brand,
        category,
        subcategory,
        unit_cost,
        list_price,
        is_active,
        pack_size,
        snapshot_date                                                     as version_date,
        iff(
            row_number() over (partition by sku order by snapshot_date) = 1,
            '1900-01-01'::date,
            snapshot_date
        )                                                                 as valid_from,
        lead(snapshot_date) over (partition by sku order by snapshot_date) as valid_to,
        _loaded_at
    from changes
),

keyed as (
    select
        s.*,
        {% if is_incremental() %} t.product_sk {% else %} null::number {% endif %} as existing_sk
    from scd2 s
    {% if is_incremental() %}
    left join {{ this }} t on t.sku = s.sku and t.version_date = s.version_date
    {% endif %}
)

select
    {{ next_surrogate_key('product_sk', 'sku, version_date') }} as product_sk,
    sku,
    product_name,
    brand,
    category,
    subcategory,
    unit_cost,
    list_price,
    is_active,
    pack_size,
    version_date,
    valid_from,
    valid_to,
    valid_to is null                                           as is_current,
    _loaded_at
from keyed

union all

-- Unknown member: sales lines whose SKU is in no catalog file point here.
select -1, 'UNKNOWN', 'Unknown', 'unknown', 'unknown', 'unknown', null, null, null, null,
       '1900-01-01'::date, '1900-01-01'::date, null, true, '1900-01-01'::timestamp_ltz
