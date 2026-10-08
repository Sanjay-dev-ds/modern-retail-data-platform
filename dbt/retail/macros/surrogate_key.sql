{#-
  Surrogate keys, Kimball style: meaningless sequential integers, assigned ONCE when a
  dimension row (version) is first inserted and never changed afterwards.

  Dimensions using this are incremental (merge). The model left-joins {{ this }} on the natural
  key + version to get `existing_sk` (null for a new row); next_surrogate_key() keeps that key,
  or hands out max(key) + 1, + 2, ... to new rows. -1 is reserved for the "Unknown" member.

  Never full-refresh a dimension on its own: keys would be re-assigned and facts that already
  hold the old keys would point at the wrong rows. Full-refresh dims and facts together.
-#}
{% macro next_surrogate_key(sk_column, order_by) -%}
    coalesce(
        existing_sk,
        {% if is_incremental() -%}
        (select greatest(coalesce(max({{ sk_column }}), 0), 0) from {{ this }})
        {%- else -%}
        0
        {%- endif %}
        + row_number() over (partition by existing_sk is null order by {{ order_by }})
    )
{%- endmacro %}
