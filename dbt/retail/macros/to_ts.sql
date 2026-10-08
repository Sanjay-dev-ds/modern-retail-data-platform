{#- Timestamp from a VARIANT field (DMS Parquet or clickstream JSON); null if unparseable. -#}
{% macro to_ts(field) -%}
    try_to_timestamp_ntz({{ field }}::string)
{%- endmacro %}
