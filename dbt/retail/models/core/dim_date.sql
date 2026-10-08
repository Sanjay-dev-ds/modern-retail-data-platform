-- Calendar from a date spine (no reference file needed).
with spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2025-01-01' as date)",
        end_date="dateadd(year, 1, current_date)"
    ) }}
)

select
    date_day                                as date_day,
    year(date_day)                          as year,
    quarter(date_day)                       as quarter,
    month(date_day)                         as month,
    monthname(date_day)                     as month_name,
    weekofyear(date_day)                    as week_of_year,
    dayofweekiso(date_day)                  as day_of_week,     -- 1 = Monday
    dayname(date_day)                       as day_name,
    dayofweekiso(date_day) in (6, 7)        as is_weekend
from spine
