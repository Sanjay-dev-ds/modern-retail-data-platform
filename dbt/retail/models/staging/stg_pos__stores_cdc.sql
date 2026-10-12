-- Every replicated version of every store (full-load row + each CDC change). Feeds dim_store (SCD2).
select
    record:"store_id"::int              as store_id,
    record:"store_name"::string         as store_name,
    record:"region"::string             as region,
    record:"format"::string             as format,
    {{ to_ts('record:"open_date"') }}::date as open_date,
    {{ to_ts('record:"updated_at"') }}  as updated_at,
    {{ cdc_columns() }}
from {{ source('raw', 'pos_stores') }}
