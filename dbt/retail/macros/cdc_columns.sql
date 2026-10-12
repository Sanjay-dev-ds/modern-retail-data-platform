{#-
  Standard CDC columns for every POS staging model, taken from the DMS record:
    cdc_operation   INSERT / UPDATE / DELETE  (DMS Op I/U/D; full-load rows carry no Op and count as INSERT)
    _dms_commit_ts  source commit time: orders the versions of a key
  plus the load metadata _file and _loaded_at (used for de-duplication and incremental watermarks).
  A DELETE row carries only the key columns; all other columns are null.
-#}
{% macro cdc_columns() -%}
    decode(coalesce(record:"Op"::string, 'I'),
           'I', 'INSERT', 'U', 'UPDATE', 'D', 'DELETE') as cdc_operation,
    {{ to_ts('record:"_dms_commit_ts"') }}               as _dms_commit_ts,
    _file,
    _loaded_at
{%- endmacro %}
