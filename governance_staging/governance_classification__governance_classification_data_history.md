{% docs governance_classification__governance_classification_data_history %}

This model maintains the historical (SCD Type 2) view of classification data.

It tracks changes over time for each column-level classification, including:
- New records
- Updated records
- Closed (expired) records

The model uses effective timestamps and change tracking fields to manage history.

{% enddocs %}


{% docs governance_classification__governance_classification_data_history__classification_id %}
Unique identifier for the classification record.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__db_name %}
Database name where the object exists.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__schema_name %}
Schema name of the object.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__table_name %}
Table name containing the column.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__column_name %}
Column name being classified.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__security_classification_code %}
Classification code assigned to the column.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__business_key_flag %}
Indicates if column is part of business key.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__primary_key_flag %}
Indicates if column is part of primary key.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__is_src_deleted %}
Flag indicating deletion in source system.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__source_ds_update %}
Timestamp when source system updated the record.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__dwh_effective_from_tstamp %}
Start timestamp of record validity.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__dwh_effective_to_tstamp %}
End timestamp of record validity.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__dwh_change_type %}
Type of change (NEW, CHANGED, UNCHANGED).
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__is_active %}
Flag indicating current active record.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__dwh_attribute_hash %}
Hash used to detect changes in attributes.
{% enddocs %}

{% docs governance_classification__governance_classification_data_history__dwh_process_tstamp %}
Timestamp when record was processed in DWH.
{% enddocs %}
