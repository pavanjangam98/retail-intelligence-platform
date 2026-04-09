# Snowflake Tag Management — UNSET Guide

> **Purpose:** Step-by-step reference for auditing and removing object tags in Snowflake across all levels: Column → Table → Schema → Database.

---

## Overview

In Snowflake, tags can be applied at four object levels. When removing tags, they **must be unset in a specific sequence** — starting from the most granular level (Column) and moving up to the broadest (Database).

| Order | Level | Object Type |
|-------|-------|-------------|
| 1 ✅ Start here | **COLUMN** | Individual column within a table |
| 2 | **TABLE** | Entire table |
| 3 | **SCHEMA** | Entire schema |
| 4 ✅ End here | **DATABASE** | Entire database |

> ⚠️ **Important:** Skipping or reversing this order may result in incomplete tag removal. Always complete all 4 steps.

---

## Step 1 — Audit: Find Existing Tags Before Removal

Before running any UNSET commands, use the queries below to identify all tags currently applied at each level.

---

### 🔹 1A. Find Tags at COLUMN Level

```sql
-- Lists all tags applied to columns in a specific table
SELECT
    TAG_DATABASE,
    TAG_SCHEMA,
    TAG_NAME,
    TAG_VALUE,
    OBJECT_DATABASE,
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COLUMN_NAME
FROM TABLE(
    SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES_ALL_COLUMNS(
        '<DATABASE_NAME>.<SCHEMA_NAME>.<TABLE_NAME>',
        'table'
    )
);
```

**Alternative — using ACCOUNT_USAGE view (all columns across account):**
```sql
SELECT
    TAG_NAME,
    TAG_VALUE,
    OBJECT_NAME       AS TABLE_NAME,
    COLUMN_NAME,
    OBJECT_SCHEMA     AS SCHEMA_NAME,
    OBJECT_DATABASE   AS DATABASE_NAME
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE DOMAIN = 'COLUMN'
  AND OBJECT_DATABASE = '<DATABASE_NAME>'    -- Replace with your DB
  AND OBJECT_SCHEMA   = '<SCHEMA_NAME>'      -- Replace with your schema
  AND OBJECT_NAME     = '<TABLE_NAME>';      -- Replace with your table
```

---

### 🔹 1B. Find Tags at TABLE Level

```sql
SELECT
    TAG_NAME,
    TAG_VALUE,
    OBJECT_NAME     AS TABLE_NAME,
    OBJECT_SCHEMA   AS SCHEMA_NAME,
    OBJECT_DATABASE AS DATABASE_NAME,
    DOMAIN
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE DOMAIN = 'TABLE'
  AND OBJECT_DATABASE = '<DATABASE_NAME>'    -- Replace with your DB
  AND OBJECT_SCHEMA   = '<SCHEMA_NAME>';     -- Replace with your schema
```

---

### 🔹 1C. Find Tags at SCHEMA Level

```sql
SELECT
    TAG_NAME,
    TAG_VALUE,
    OBJECT_NAME     AS SCHEMA_NAME,
    OBJECT_DATABASE AS DATABASE_NAME,
    DOMAIN
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE DOMAIN = 'SCHEMA'
  AND OBJECT_DATABASE = '<DATABASE_NAME>';   -- Replace with your DB
```

---

### 🔹 1D. Find Tags at DATABASE Level

```sql
SELECT
    TAG_NAME,
    TAG_VALUE,
    OBJECT_NAME AS DATABASE_NAME,
    DOMAIN
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE DOMAIN = 'DATABASE'
  AND OBJECT_NAME = '<DATABASE_NAME>';       -- Replace with your DB
```

---

### 🔹 1E. Find ALL Tags Across All Levels (Single Query)

Use this query to get a complete picture across all levels at once:

```sql
SELECT
    DOMAIN,
    TAG_DATABASE,
    TAG_SCHEMA,
    TAG_NAME,
    TAG_VALUE,
    OBJECT_DATABASE,
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COLUMN_NAME
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE OBJECT_DATABASE = '<DATABASE_NAME>'   -- Replace with your DB
ORDER BY
    FIELD(DOMAIN, 'COLUMN', 'TABLE', 'SCHEMA', 'DATABASE'),
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COLUMN_NAME;
```

> 📝 **Note:** `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES` may have a latency of up to **2 hours**. For real-time results, use the `TAG_REFERENCES_ALL_COLUMNS()` table function or `SYSTEM$GET_TAG()` shown below.

---

### 🔹 1F. Check a Specific Tag Value on an Object (Real-Time)

```sql
-- Check tag on a COLUMN
SELECT SYSTEM$GET_TAG(
    '<TAG_DB>.<TAG_SCHEMA>.<TAG_NAME>',          -- Fully qualified tag name
    '<DB>.<SCHEMA>.<TABLE>.<COLUMN_NAME>',        -- Fully qualified column
    'COLUMN'
);

-- Check tag on a TABLE
SELECT SYSTEM$GET_TAG(
    '<TAG_DB>.<TAG_SCHEMA>.<TAG_NAME>',
    '<DB>.<SCHEMA>.<TABLE_NAME>',
    'TABLE'
);

-- Check tag on a SCHEMA
SELECT SYSTEM$GET_TAG(
    '<TAG_DB>.<TAG_SCHEMA>.<TAG_NAME>',
    '<DB>.<SCHEMA_NAME>',
    'SCHEMA'
);

-- Check tag on a DATABASE
SELECT SYSTEM$GET_TAG(
    '<TAG_DB>.<TAG_SCHEMA>.<TAG_NAME>',
    '<DATABASE_NAME>',
    'DATABASE'
);
```

---

## Step 2 — Remove Tags Using UNSET (Follow This Sequence)

Once you've identified all tags from Step 1, run the UNSET commands in the order below.

---

### ✅ Step 2.1 — UNSET at COLUMN Level (Start Here)

```sql
-- Unset a single tag from one column
ALTER TABLE <DATABASE_NAME>.<SCHEMA_NAME>.<TABLE_NAME>
    MODIFY COLUMN <COLUMN_NAME>
    UNSET TAG <TAG_DATABASE>.<TAG_SCHEMA>.<TAG_NAME>;
```

**Example:**
```sql
ALTER TABLE MY_DB.MY_SCHEMA.EMPLOYEE
    MODIFY COLUMN SSN
    UNSET TAG GOVERNANCE_DB.TAGS.PII_TAG;
```

**Unset multiple tags from one column at once:**
```sql
ALTER TABLE MY_DB.MY_SCHEMA.EMPLOYEE
    MODIFY COLUMN SSN
    UNSET TAG
        GOVERNANCE_DB.TAGS.PII_TAG,
        GOVERNANCE_DB.TAGS.SENSITIVITY_TAG;
```

---

### ✅ Step 2.2 — UNSET at TABLE Level

```sql
-- Unset a single tag from a table
ALTER TABLE <DATABASE_NAME>.<SCHEMA_NAME>.<TABLE_NAME>
    UNSET TAG <TAG_DATABASE>.<TAG_SCHEMA>.<TAG_NAME>;
```

**Example:**
```sql
ALTER TABLE MY_DB.MY_SCHEMA.EMPLOYEE
    UNSET TAG GOVERNANCE_DB.TAGS.CONFIDENTIAL_TAG;
```

**Unset multiple tags from a table:**
```sql
ALTER TABLE MY_DB.MY_SCHEMA.EMPLOYEE
    UNSET TAG
        GOVERNANCE_DB.TAGS.CONFIDENTIAL_TAG,
        GOVERNANCE_DB.TAGS.DEPT_TAG;
```

---

### ✅ Step 2.3 — UNSET at SCHEMA Level

```sql
-- Unset a single tag from a schema
ALTER SCHEMA <DATABASE_NAME>.<SCHEMA_NAME>
    UNSET TAG <TAG_DATABASE>.<TAG_SCHEMA>.<TAG_NAME>;
```

**Example:**
```sql
ALTER SCHEMA MY_DB.MY_SCHEMA
    UNSET TAG GOVERNANCE_DB.TAGS.DATA_DOMAIN_TAG;
```

---

### ✅ Step 2.4 — UNSET at DATABASE Level (End Here)

```sql
-- Unset a single tag from a database
ALTER DATABASE <DATABASE_NAME>
    UNSET TAG <TAG_DATABASE>.<TAG_SCHEMA>.<TAG_NAME>;
```

**Example:**
```sql
ALTER DATABASE MY_DB
    UNSET TAG GOVERNANCE_DB.TAGS.ENV_TAG;
```

---

## Step 3 — Verify Tags Have Been Removed

After running all UNSET commands, re-run the audit queries from Step 1 to confirm no tags remain.

```sql
-- Quick verification — should return 0 rows if all tags are removed
SELECT
    DOMAIN,
    TAG_NAME,
    TAG_VALUE,
    OBJECT_NAME,
    COLUMN_NAME
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE OBJECT_DATABASE = '<DATABASE_NAME>'
ORDER BY DOMAIN, OBJECT_NAME;
```

> ⏱️ If using ACCOUNT_USAGE, allow up to **2 hours** for the view to reflect changes. For immediate verification, use `SYSTEM$GET_TAG()` (see Step 1F).

---

## Quick Reference Summary

| Level | Audit Query Source | UNSET Syntax |
|-------|--------------------|--------------|
| **Column** | `TAG_REFERENCES` where `DOMAIN = 'COLUMN'` | `ALTER TABLE … MODIFY COLUMN … UNSET TAG …` |
| **Table** | `TAG_REFERENCES` where `DOMAIN = 'TABLE'` | `ALTER TABLE … UNSET TAG …` |
| **Schema** | `TAG_REFERENCES` where `DOMAIN = 'SCHEMA'` | `ALTER SCHEMA … UNSET TAG …` |
| **Database** | `TAG_REFERENCES` where `DOMAIN = 'DATABASE'` | `ALTER DATABASE … UNSET TAG …` |

---

## Required Privileges

To run UNSET commands, the role executing the commands must have:

| Privilege | Required On |
|-----------|-------------|
| `APPLY` on the TAG | Tag object |
| `OWNERSHIP` or `ALTER` | The object being modified (column/table/schema/database) |

```sql
-- Grant APPLY privilege on a tag to a role
GRANT APPLY ON TAG GOVERNANCE_DB.TAGS.PII_TAG TO ROLE DATA_STEWARD;
```

---

## Notes & Best Practices

- **Always audit before unsetting** — run Step 1 queries first to know exactly which tags exist.
- **Order is mandatory** — always unset Column → Table → Schema → Database.
- **Tags are not inherited** — a tag set at DATABASE level does not automatically appear on tables/columns. Each level is independent.
- **Fully qualify tag names** — always use `<TAG_DB>.<TAG_SCHEMA>.<TAG_NAME>` format to avoid ambiguity.
- **ACCOUNT_USAGE latency** — the `TAG_REFERENCES` view has up to 2-hour latency. Use `SYSTEM$GET_TAG()` for real-time checks.
- **Dropping a tag** — if you plan to drop the tag object itself, all references must be unset first or use `DROP TAG … FORCE`.

---

*Last Updated: April 2026 | Platform: Snowflake*
