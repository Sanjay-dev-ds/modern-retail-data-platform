-- One row per SKU per daily snapshot. The snapshot date comes from the file path (dt=YYYY-MM-DD).
with snapshots as (
    select
        *,
        to_date(regexp_substr(_file, 'dt=([0-9]{4}-[0-9]{2}-[0-9]{2})', 1, 1, 'e', 1)) as snapshot_date
    from {{ source('raw', 'catalog_products') }}
)

select
    sku,
    product_name,
    brand,
    category,
    subcategory,
    unit_cost,
    list_price,
    is_active,
    supplier_updated_at,
    pack_size,          -- null before the supplier added the column
    snapshot_date,
    _file,
    _loaded_at
from snapshots
qualify row_number() over (partition by sku, snapshot_date order by _file desc) = 1
