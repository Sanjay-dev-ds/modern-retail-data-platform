{% docs col__loaded_at %}
When Snowflake loaded the row (COPY INTO time). Incremental models use it as the watermark,
because it reflects when data *arrived*, including late data.
{% enddocs %}

{% docs col__file %}
Path of the S3 file the row was loaded from, relative to the stage.
{% enddocs %}

{% docs col__dms_commit_ts %}
Commit time of the change in the source database, written by DMS. Orders the versions of a key;
the latest one is the current state.
{% enddocs %}

{% docs col_is_deleted %}
True when the source row was hard-deleted (DMS `Op = 'D'`). Delete rows carry only the key
columns, all other columns are null. Exclude these rows in reporting.
{% enddocs %}

{% docs col_version_ts %}
Source commit time of this version (`_dms_commit_ts`). Natural key + version identify a
dimension row and drive the incremental merge.
{% enddocs %}

{% docs col_valid_from %}
Start of the period this version is valid (inclusive). The first version of each key starts
1900-01-01, because history before the DMS full load is unknown.
{% enddocs %}

{% docs col_valid_to %}
End of the period this version is valid (exclusive). Null for the current version.
{% enddocs %}

{% docs col_is_current %}
True for the current (latest) version of the key.
{% enddocs %}

{% docs col_surrogate_key %}
Surrogate key: meaningless sequential integer, assigned once when this version is first created
and never changed. `-1` = Unknown member.
{% enddocs %}

{% docs col_store_id %}
Store business key from the POS system. `0` = the online shop.
{% enddocs %}

{% docs col_customer_id %}
Loyalty customer business key from the POS system. Null = anonymous (no loyalty card).
{% enddocs %}

{% docs col_transaction_id %}
Sale (order) identifier from the POS system, UUID. For online orders it equals the clickstream
`order_id` of the purchase event.
{% enddocs %}

{% docs col_sku %}
Product code (`SKU-00042`). Owned by the supplier catalog file; POS lines may contain SKUs that
are in no catalog file (planted orphan-SKU defect).
{% enddocs %}

{% docs col_channel %}
Sales channel: `store` (physical store) or `online` (store_id 0).
{% enddocs %}

{% docs col_status %}
Sale status: `completed`; `voided` (cancelled at the till, minutes after the sale); or
`returned` (brought back, days later). Voids and returns are fully refunded in payments.
{% enddocs %}

{% docs col_txn_ts %}
Business time of the sale (UTC). Use this for reporting, not load times.
{% enddocs %}

{% docs col_region %}
Store region: north, south, east, west, or online.
{% enddocs %}

{% docs col_format %}
Store format: hyper, express, outlet, or online.
{% enddocs %}

{% docs col_loyalty_tier %}
Loyalty tier: bronze, silver, gold. New sign-ups start at bronze; tiers change over time (SCD2).
{% enddocs %}

{% docs col_email %}
Customer email (PII). Nullable: some sign-ups skip it (planted null-values defect), and some are
fixed later.
{% enddocs %}

{% docs col_payment_method %}
Tender type: card, cash (stores only), wallet, gift_card.
{% enddocs %}

{% docs col_unit_price %}
Price charged per unit on the sale. Can differ from the catalog `list_price` of that day.
{% enddocs %}
