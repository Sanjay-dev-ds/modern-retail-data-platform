-- SCD2 product dimension from the supplier's daily full snapshots: compare each day with the
-- previous one and open a new version only when an attribute changed (price, active flag, ...).
with snapshots as (
    select
        *,
        md5(concat_ws('|', product_name, brand, category, subcategory, unit_cost, list_price, is_active)) as attr_hash
    from {{ ref('stg_catalog__products') }}
),

changes as (
    select *
    from snapshots
    qualify lag(attr_hash) over (partition by sku order by snapshot_date) is distinct from attr_hash
)

select
    {{ dbt_utils.generate_surrogate_key(['sku', 'snapshot_date']) }} as product_sk,
    sku,
    product_name,
    brand,
    category,
    subcategory,
    unit_cost,
    list_price,
    is_active,
    pack_size,
    iff(
        row_number() over (partition by sku order by snapshot_date) = 1,
        '1900-01-01'::date,
        snapshot_date
    )                                                                 as valid_from,
    lead(snapshot_date) over (partition by sku order by snapshot_date) as valid_to,
    valid_to is null                                                  as is_current
from changes
