-- Daily web funnel: sessions reaching each step, and conversion.
select
    session_start::date                         as session_date,
    count(*)                                    as sessions,
    count_if(viewed_product)                    as viewed_product,
    count_if(added_to_cart)                     as added_to_cart,
    count_if(started_checkout)                  as started_checkout,
    count_if(purchased)                         as purchased,
    div0(count_if(purchased), count(*))         as conversion_rate
from {{ ref('fct_sessions') }}
group by all
