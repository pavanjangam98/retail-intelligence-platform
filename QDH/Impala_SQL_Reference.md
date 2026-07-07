# Impala SQL Reference

## 1. Show Databases

``` sql
SHOW DATABASES;
```

------------------------------------------------------------------------

## 2. Use a Database

``` sql
USE database_name;
```

Example:

``` sql
USE sales_db;
```

------------------------------------------------------------------------

## 3. Show Tables

``` sql
SHOW TABLES;
```

Specific database:

``` sql
SHOW TABLES IN sales_db;
```

------------------------------------------------------------------------

## 4. Describe Table Structure

``` sql
DESCRIBE table_name;
```

Example:

``` sql
DESCRIBE employee;
```

------------------------------------------------------------------------

## 5. Detailed Table Information

``` sql
DESCRIBE FORMATTED table_name;
```

Shows: - Columns - Data types - Table location - Owner - File format -
Table type - SerDe information - Statistics

------------------------------------------------------------------------

## 6. Show CREATE TABLE (DDL)

``` sql
SHOW CREATE TABLE table_name;
```

Example:

``` sql
SHOW CREATE TABLE employee;
```

------------------------------------------------------------------------

## 7. Show Partitions

``` sql
SHOW PARTITIONS table_name;
```

------------------------------------------------------------------------

## 8. Show Table Statistics

``` sql
SHOW TABLE STATS table_name;
```

------------------------------------------------------------------------

## 9. Show Column Statistics

``` sql
SHOW COLUMN STATS table_name;
```

------------------------------------------------------------------------

## 10. View Sample Data

``` sql
SELECT *
FROM table_name
LIMIT 10;
```

------------------------------------------------------------------------

## 11. Count Rows

``` sql
SELECT COUNT(*)
FROM table_name;
```

------------------------------------------------------------------------

## 12. Refresh Metadata

``` sql
REFRESH table_name;
```

------------------------------------------------------------------------

## 13. Reload Metadata (Schema Changes)

``` sql
INVALIDATE METADATA table_name;
```

------------------------------------------------------------------------

## 14. Show Views

``` sql
SHOW VIEWS;
```

------------------------------------------------------------------------

## 15. Show Functions

``` sql
SHOW FUNCTIONS;
```

------------------------------------------------------------------------

# Useful Queries

## List All Databases

``` sql
SHOW DATABASES;
```

## List All Tables in Current Database

``` sql
SHOW TABLES;
```

## List Tables in Another Database

``` sql
SHOW TABLES IN database_name;
```

## Find Tables Matching a Pattern

``` sql
SHOW TABLES LIKE 'emp*';
```

## Describe Table

``` sql
DESCRIBE table_name;
```

## Detailed Metadata

``` sql
DESCRIBE FORMATTED table_name;
```

## Get CREATE TABLE Script

``` sql
SHOW CREATE TABLE table_name;
```

## Check Partitions

``` sql
SHOW PARTITIONS table_name;
```

## Check Table Stats

``` sql
SHOW TABLE STATS table_name;
```

## Check Column Stats

``` sql
SHOW COLUMN STATS table_name;
```

## Preview Data

``` sql
SELECT * FROM table_name LIMIT 10;
```

## Count Records

``` sql
SELECT COUNT(*) FROM table_name;
```

## Refresh Table

``` sql
REFRESH table_name;
```

## Reload Metadata

``` sql
INVALIDATE METADATA table_name;
```

------------------------------------------------------------------------

# Cheat Sheet

``` sql
SHOW DATABASES;
USE database_name;
SHOW TABLES;
SHOW TABLES IN database_name;
SHOW TABLES LIKE 'pattern*';

DESCRIBE table_name;
DESCRIBE FORMATTED table_name;

SHOW CREATE TABLE table_name;

SHOW PARTITIONS table_name;

SHOW TABLE STATS table_name;
SHOW COLUMN STATS table_name;

SELECT * FROM table_name LIMIT 10;
SELECT COUNT(*) FROM table_name;

REFRESH table_name;
INVALIDATE METADATA table_name;

SHOW VIEWS;
SHOW FUNCTIONS;
```
