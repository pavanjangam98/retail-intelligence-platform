{% docs governance_staging__governance_classification_data %}

This model provides column-level classification details for governance tracking.

It contains metadata about database objects, including classification codes,
data types, and business/primary key indicators.

The model is built as a staging layer and serves as the source for downstream
classification history and active views.

{% enddocs %}


{% docs governance_staging__governance_classification_data__object_id %}
Unique identifier for the object record.
{% enddocs %}

{% docs governance_staging__governance_classification_data__db_name %}
Name of the database where the object resides.
{% enddocs %}

{% docs governance_staging__governance_classification_data__schema_name %}
Name of the schema containing the object.
{% enddocs %}

{% docs governance_staging__governance_classification_data__table_name %}
Name of the table containing the column.
{% enddocs %}

{% docs governance_staging__governance_classification_data__column_name %}
Name of the column being classified.
{% enddocs %}

{% docs governance_staging__governance_classification_data__security_classification_code %}
Security classification assigned to the column.
{% enddocs %}

{% docs governance_staging__governance_classification_data__source_system %}
Source system from which the data is derived.
{% enddocs %}

{% docs governance_staging__governance_classification_data__zone_name %}
Data zone classification (e.g., raw, curated, trusted).
{% enddocs %}

{% docs governance_staging__governance_classification_data__env_name %}
Environment name (e.g., DEV, UAT, PROD).
{% enddocs %}

{% docs governance_staging__governance_classification_data__business_key_flag %}
Indicates whether the column is part of a business key (Y/N).
{% enddocs %}

{% docs governance_staging__governance_classification_data__primary_key_flag %}
Indicates whether the column is part of a primary key (Y/N).
{% enddocs %}

{% docs governance_staging__governance_classification_data__data_type %}
Data type of the column.
{% enddocs %}

{% docs governance_staging__governance_classification_data__is_src_deleted %}
Flag indicating if the record is marked as deleted in the source system.
{% enddocs %}

{% docs governance_staging__governance_classification_data__source_ds_update %}
Timestamp when the source system last updated the record.
{% enddocs %}

{% docs governance_staging__governance_classification_data__record_created_at %}
Timestamp when the record was created in the data platform.
{% enddocs %}

{% docs governance_staging__governance_classification_data__record_updated_at %}
Timestamp when the record was last updated in the data platform.
{% enddocs %}
