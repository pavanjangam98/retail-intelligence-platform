{% docs governance_classification__classification_active %}

This view provides the current active classification records.

It is derived from the classification history model and filters:
- Only active records
- Only relevant change types (NEW, CHANGED)
- Excludes deleted records

This view is used for reporting and downstream consumption.

{% enddocs %}


{% docs governance_classification__classification_active__classification_id %}
Unique identifier for the classification record.
{% enddocs %}

{% docs governance_classification__classification_active__db_name %}
Database name where the object exists.
{% enddocs %}

{% docs governance_classification__classification_active__schema_name %}
Schema name of the object.
{% enddocs %}

{% docs governance_classification__classification_active__table_name %}
Table name containing the column.
{% enddocs %}

{% docs governance_classification__classification_active__column_name %}
Column name being classified.
{% enddocs %}

{% docs governance_classification__classification_active__security_classification_code %}
Classification code assigned to the column.
{% enddocs %}

{% docs governance_classification__classification_active__business_key_flag %}
Indicates if column is part of business key.
{% enddocs %}

{% docs governance_classification__classification_active__primary_key_flag %}
Indicates if column is part of primary key.
{% enddocs %}

{% docs governance_classification__classification_active__is_src_deleted %}
Indicates if the record is deleted in source.
{% enddocs %}
