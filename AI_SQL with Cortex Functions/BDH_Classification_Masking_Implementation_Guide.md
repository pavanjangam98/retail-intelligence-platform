# BDH Classification & Masking - Implementation Guide
## Complete Understanding Document with Key Questions for Users

---

## 📚 TABLE OF CONTENTS

1. [Executive Summary](#executive-summary)
2. [Key Terms & Glossary](#key-terms--glossary)
3. [Architecture Overview](#architecture-overview)
4. [Key Design Decisions (KDDs)](#key-design-decisions-kdds)
5. [Implementation Components](#implementation-components)
6. [Critical Questions to Ask Users](#critical-questions-to-ask-users)
7. [Implementation Checklist](#implementation-checklist)
8. [Role-Based Access Matrix](#role-based-access-matrix)
9. [Data Flow & Integration Points](#data-flow--integration-points)
10. [Regulatory & Compliance Requirements](#regulatory--compliance-requirements)

---

## 📋 EXECUTIVE SUMMARY

### What is This Solution?
This is a **data classification and masking framework** that:
- Uses **Alation** (data catalog tool) to automatically classify sensitive data
- Uses **Snowflake** (data warehouse) to apply dynamic masking based on classifications
- Ensures compliance with PCI DSS, APRA, Privacy Act, and internal GIRP policies
- Provides role-based access control (RBAC) for different user personas

### The Big Picture
```
Alation (Scan & Classify) 
    ↓
Alation Analytics (Metadata Repository)
    ↓
Snowflake Secure Data Share (Transfer Classifications)
    ↓
Governance Database (Store Classifications)
    ↓
DBT Macros (Apply Tags)
    ↓
Masking Policies (Enforce Access Control)
```

### Key Outcomes
✅ Automated data classification (no manual tagging by engineers)  
✅ Consistent masking across DEV, SYST, PPTE, PROD environments  
✅ Role-based data visibility (different users see different data)  
✅ Regulatory compliance (PCI, PII, APRA requirements met)  
✅ Scalable and maintainable (uses native Snowflake features)  

---

## 🔑 KEY TERMS & GLOSSARY

### Core Technologies

| Term | Full Name | Definition | Example |
|------|-----------|------------|---------|
| **BDH** | Big Data Hub | Bank's Snowflake-based data warehouse platform | The entire Snowflake environment at BNZ |
| **Alation** | Alation Data Catalog | Third-party data governance tool that scans databases and applies classifications | Software that identifies "Name" column as PII |
| **Alation Analytics** | Alation Analytics Database | Snowflake database provided by Alation containing metadata about classifications | Database with table listing all classified columns |
| **Snowflake** | Snowflake Data Cloud | Cloud data warehouse where data is stored and queried | Where all BNZ analytics data lives |
| **DBT** | Data Build Tool | Tool for transforming data and managing data pipelines | Used to apply tags to tables after creation |
| **RBAC** | Role-Based Access Control | Security model where access is granted based on user roles | "Developer" role sees masked data, "Analyst" sees clear data |

### Data Classification Levels

| Classification | Description | Example Data | Access Level |
|----------------|-------------|--------------|--------------|
| **Public** | Non-sensitive, can be shared openly | Product categories, public rates | Everyone can see in clear |
| **Private** | Internal use, not publicly disclosed | Internal reports, branch names | Most staff can see in clear |
| **Confidential** | Sensitive business data requiring protection | Customer addresses, account balances | Limited staff, some masking |
| **Highly Confidential** | Extremely sensitive, regulatory/legal protection required | Credit card numbers (PAN), Tax IDs, Health info | Very limited access, heavily masked |
| **Unclassified** | Not yet classified by Alation | New columns not yet scanned | Treated as Highly Confidential (safe default) |

### Key Data Types

| Term | Full Name | Definition | Regulatory Requirement |
|------|-----------|------------|------------------------|
| **PII** | Personally Identifiable Information | Data that can identify an individual | Privacy Act 2020 |
| **PCI** | Payment Card Industry Data | Credit/debit card information | PCI DSS Standards |
| **PAN** | Primary Account Number | Credit card number (16 digits) | PCI DSS - Must mask/tokenize |
| **BIN** | Bank Identification Number | First 6 digits of card number | PCI - Can be shown |
| **SAD** | Sensitive Authentication Data | CVV, PIN, full magnetic stripe | PCI DSS - Never store after auth |
| **PHI** | Protected Health Information | Medical/health records | Privacy standards |

### Environment Types

| Environment | Purpose | Alation Scanning | Data Sensitivity |
|-------------|---------|------------------|------------------|
| **DEV** | Development and testing | ✅ Actively scanned | Can contain PROD-like masked data |
| **SYST** | System integration testing | ❌ Uses DEV classifications | Same as DEV |
| **PPTE** | Pre-production testing | ✅ Actively scanned | Production-like data, masked |
| **PROD** | Production (live customer data) | ⚠️ Scanned for compliance only | Real customer data, heavily protected |
| **NON-PROD** | General term for DEV/SYST/PPTE | Varies | Should not contain real PROD data |

### Snowflake Components

| Component | Description | Purpose in This Solution |
|-----------|-------------|--------------------------|
| **Tag** | Metadata label attached to columns/tables | Stores classification (e.g., "HIGHLY_CONFIDENTIAL") |
| **Masking Policy** | Rule that transforms data based on conditions | Hides/hashes data for unauthorized users |
| **Secure Data Share** | Snowflake native data sharing between accounts | Transfers classifications from Alation Analytics to Snowflake |
| **Role** | User permission group | Determines what data a user can see |
| **Schema** | Container for database objects (tables, views) | Organizational structure within database |
| **Database** | Top-level container in Snowflake | Example: GOVERNANCE_DB, LANDING_DB |

### Data Zones (Layers)

| Zone | Layer | Purpose | Who Accesses |
|------|-------|---------|--------------|
| **Landing Zone** | Landing Layer | Raw data ingestion, initial landing | Landing Developers only |
| **Subject Area Zone** | Raw Layer | Business domain organized data | Subject Area Developers |
| **Foundation Zone** | Foundation Layer | Cleaned, standardized data | Foundation Developers |
| **Curated Zone** | Curated Layer | Business-ready, aggregated data | Consumers, Analysts |
| **Transform Zone** | Development Sandbox | Individual developer workspace | Assigned Developer (isolated) |

### Key Roles & Personas

| Persona | Environment | Access Level | Can See |
|---------|-------------|--------------|---------|
| **Landing Developer** | DEV/PPTE | Highly Confidential Access | Everything including unclassified data |
| **Landing Developer (Restricted)** | DEV/PPTE | Extra Restricted | Highly sensitive sources only |
| **Subject Area Developer** | DEV/PPTE | Highly Confidential or Confidential | Depends on role assignment |
| **Foundation Developer** | DEV/PPTE | Confidential or Private | Refined data only |
| **Curated Developer** | DEV/PPTE | Private or Public | Business-ready data |
| **Transform Developer** | DEV | Special unmasked access | Only their own schema |
| **Consumer/Analyst** | All | Public or Private | Final outputs only |
| **Service Account** | All | Automated processing | No human access |

### Alation Concepts

| Term | Definition | Usage in Solution |
|------|------------|-------------------|
| **Catalog Set** | Group of data objects with shared characteristics | Groups columns by regex pattern for auto-classification |
| **Data Source** | Connection to a database/system for scanning | Separate data sources for PRE-PROD vs PROD Snowflake |
| **Custom Field** | User-defined metadata field | Stores `SECURITY_CLASSIFICATION_CODE` |
| **Conditional Catalog Set** | Auto-grouping based on logical conditions | Automatically classifies columns matching regex patterns |
| **Manual Catalog Set** | Manually selected groupings | Used for exceptions or one-off classifications |
| **Catalog Page** | Information page for a data asset | Shows classification, description, stewards |

### Key Metrics & Patterns

| Concept | Description | Example |
|---------|-------------|---------|
| **24-Hour Sync** | Frequency of Alation → Alation Analytics updates | Classifications refresh daily |
| **1:1 Mapping** | PRE-PROD and PROD configurations are identical | Same Catalog Sets used in both |
| **Environment Pairing** | DEV↔SYST, PPTE↔PROD share classifications | SYST inherits from DEV |
| **Scan Scope** | Landing, Raw, Foundation, Curated layers scanned | All zones except Transform DB |
| **Hash vs Mask** | Hash preserves joinability, Mask hides completely | Keys are hashed, PII is masked |

---

## 🏗️ ARCHITECTURE OVERVIEW

### High-Level Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    ALATION (Single Instance)                 │
│  ┌────────────────────┐         ┌────────────────────┐      │
│  │  PRE-PROD Config   │         │    PROD Config     │      │
│  │  - Data Sources    │         │  - Data Sources    │      │
│  │  - Catalog Sets    │         │  - Catalog Sets    │      │
│  └─────────┬──────────┘         └──────────┬─────────┘      │
│            │                               │                │
│            └───────────┬───────────────────┘                │
│                        ▼                                     │
│              ┌──────────────────────┐                        │
│              │ Alation Analytics DB │ (Metadata Repository)  │
│              └──────────┬───────────┘                        │
└────────────────────────┼────────────────────────────────────┘
                         │
         ┌───────────────┴────────────────┐
         │                                │
         ▼                                ▼
┌─────────────────────┐         ┌─────────────────────┐
│  SNOWFLAKE PRE-PROD │         │   SNOWFLAKE PROD    │
│  ┌───────────────┐  │         │  ┌───────────────┐  │
│  │ Secure Share  │  │         │  │ Secure Share  │  │
│  └───────┬───────┘  │         │  └───────┬───────┘  │
│          ▼          │         │          ▼          │
│  ┌───────────────┐  │         │  ┌───────────────┐  │
│  │ Governance DB │  │         │  │ Governance DB │  │
│  └───────┬───────┘  │         │  └───────┬───────┘  │
│          │          │         │          │          │
│  ┌───────▼───────┐  │         │  ┌───────▼───────┐  │
│  │  DEV   SYST   │  │         │  │  PPTE   PROD  │  │
│  │ (Tagged Data) │  │         │  │ (Tagged Data) │  │
│  └───────────────┘  │         │  └───────────────┘  │
│                     │         │                     │
│  DBT applies tags   │         │  DBT applies tags   │
│  Masking enforced   │         │  Masking enforced   │
└─────────────────────┘         └─────────────────────┘
```

### Component Numbering Reference

| # | Component | Environment | Key Action |
|---|-----------|-------------|------------|
| 1 | Alation Scan DEV | Snowflake DEV | Scan tables/columns, classify |
| 2 | Alation → Analytics | Alation | Daily ETL sync (24hr) |
| 3 | Analytics → Snowflake | PRE-PROD Account | Secure data share |
| 4 | Governance DB (PRE-PROD) | PRE-PROD Account | Store classifications |
| 5 | Apply Tags DEV | Snowflake DEV | DBT post-hooks apply tags |
| 6 | Masking DEV | Snowflake DEV | Dynamic masking enforced |
| 7 | Masking SYST | Snowflake SYST | Inherit DEV tags, apply masking |
| 8 | Promote Alation Config | Alation | Copy to PROD configuration |
| 9 | Alation Scan PPTE | Snowflake PPTE | Scan tables/columns, classify |
| 10 | Alation → Analytics (PROD) | Alation | Daily ETL sync (24hr) |
| 11 | Analytics → Snowflake (PROD) | PROD Account | Secure data share |
| 12 | Governance DB (PROD) | PROD Account | Store classifications |
| 13 | Apply Tags PPTE | Snowflake PPTE | DBT post-hooks apply tags |
| 14 | Masking PPTE | Snowflake PPTE | Dynamic masking enforced |
| 15 | Masking PROD | Snowflake PROD | Inherit PPTE tags, apply masking |
| 16 | Compliance Scan PROD | Snowflake PROD | Validation only, no changes |

---

## 🎯 KEY DESIGN DECISIONS (KDDs)

### KDD01: Alation Owns Classification (Not Engineers)
**Decision:** Alation automatically classifies data; engineers do NOT manually set classifications in DBT.  
**Rationale:** Centralized governance, consistency across all data sources, prevents human error.  
**Impact:** Engineers must wait for Alation scan before classifications appear.

**Questions to Ask Users:**
- Are data stewards trained in Alation to create/manage Catalog Sets?
- What is the process for requesting a new classification or appealing an incorrect one?
- How quickly can Alation rescan after new tables are created?

---

### KDD02 & KDD09: Use Alation Analytics (Not API)
**Decision:** Use native Snowflake Secure Data Share from Alation Analytics instead of API integration.  
**Rationale:** More performant, secure, no complex middleware, leverages Snowflake native features.  
**Impact:** Requires Alation Analytics license and Snowflake account setup.

**Questions to Ask Users:**
- Is Alation Analytics already provisioned and accessible?
- Are Snowflake accounts configured to receive secure shares from Alation?
- Who manages the Alation Analytics to Snowflake data share?

---

### KDD03: Scan DEV & PPTE, Inherit for SYST & PROD
**Decision:**  
- DEV is scanned → SYST uses DEV's classifications
- PPTE is scanned → PROD uses PPTE's classifications  
- PROD is scanned only for compliance validation

**Rationale:** Reduces scanning overhead, ensures consistency, assumes code promotion brings same structure.  
**Impact:** SYST and PROD don't get independent classifications; changes must go through DEV/PPTE first.

**Questions to Ask Users:**
- Is your code promotion process strict (DEV→SYST→PPTE→PROD)?
- Are table structures guaranteed to be identical between paired environments?
- How do you handle hotfixes that bypass DEV/PPTE?

---

### KDD04: Scan Landing Zone
**Decision:** Alation scans Landing Zone (not just downstream layers).  
**Rationale:** Early visibility into data classification, better governance at ingestion point.  
**Impact:** Landing developers must understand classifications early; semi-structured data defaults to "Unclassified."

**Questions to Ask Users:**
- Do Landing developers understand they'll see "Unclassified" for nested JSON/Parquet until flattened?
- Are Landing developers aware they need "Highly Confidential" role to access Landing?
- Is there a process to quickly classify common Landing patterns?

---

### KDD05: Landing Zone Highly Confidential Role
**Decision:** Landing developers get full access to Highly Confidential + Unclassified data.  
**Rationale:** Need to validate ingestion pipelines, flatten semi-structured data.  
**Impact:** Landing developers are privileged users; strict access controls needed.

**Questions to Ask Users:**
- How many Landing developers exist? (Should be minimal)
- Is there a background check/approval process for Landing developer access?
- Are Landing developer activities audited?

---

### KDD06: Subject Area Zone Has 3 Roles
**Decision:** Three roles in Subject Area Zone:
1. Highly Confidential access
2. Confidential access  
3. Private access

**Rationale:** Granular access control based on data sensitivity.  
**Impact:** Role provisioning becomes more complex; users must request appropriate role.

**Questions to Ask Users:**
- Who approves role assignments for each classification level?
- How are users onboarded and assigned to the right role?
- Is there a self-service portal or is it manual?

---

### KDD07: Only SECURITY_CLASSIFICATION_CODE Drives Masking
**Decision:** Masking is ONLY based on `SECURITY_CLASSIFICATION_CODE` tag (Highly Confidential, Confidential, Private, Public).  
Other Alation fields (e.g., PII flag, PCI flag) are for compliance reporting only.

**Rationale:** Simplifies masking logic, avoids conflicting rules.  
**Impact:** All masking behavior is determined by one field; other flags don't change data visibility.

**Questions to Ask Users:**
- Do users understand that PII/PCI flags in Alation are informational only?
- Are there any use cases where masking needs to consider multiple classification dimensions?
- How are exceptions handled (e.g., audit team needs Highly Confidential access)?

---

### KDD08: Hash Keys, Don't Mask Them
**Decision:** Business Keys (BK), Primary Keys (PK), Foreign Keys (FK) are **hashed** instead of masked.  
**Rationale:** Preserves joinability across tables while still protecting the actual value.  
**Impact:** Developers can join tables using hashed keys but can't see actual values.

**Questions to Ask Users:**
- How are Business Keys identified? (Manual in Alation? Naming convention? DBT YAML?)
- Is hashing acceptable for your use case, or do some teams need clear keys?
- What hashing algorithm is used (e.g., SHA-256)?

---

## 🔧 IMPLEMENTATION COMPONENTS

### Component 1: Alation Scan of Snowflake DEV

**What Happens:**
- Alation connects to Snowflake DEV databases
- Scans Landing, Raw, Foundation, Curated layers
- Applies Catalog Set rules to auto-classify columns
- Stores classification in `SECURITY_CLASSIFICATION_CODE` custom field

**Key Configuration:**
- Alation Data Source: `PRE-PROD Snowflake Data Source`
- Catalog Sets: Conditional sets based on regex patterns
- Scan Frequency: Typically daily or on-demand

**Questions to Ask:**
- Which databases/schemas are in scope for scanning?
- Are Catalog Sets already configured with regex patterns?
- Who maintains and updates Catalog Sets as new data patterns emerge?
- How long does a full scan take?

---

### Component 2: Integration Alation → Alation Analytics

**What Happens:**
- Daily ETL process (every 24 hours)
- Classifications from Alation custom fields → Alation Analytics tables
- Metadata synchronized including table names, column names, classifications

**Key Configuration:**
- Schedule: 24-hour refresh
- Alation Analytics database in Snowflake (hosted by Alation)

**Questions to Ask:**
- Is the 24-hour sync acceptable, or do you need faster updates?
- Who is notified if the ETL job fails?
- Can you trigger a manual refresh if needed?

---

### Component 3: Secure Data Share to Snowflake PRE-PROD

**What Happens:**
- Alation Analytics shares metadata to Snowflake PRE-PROD account
- Uses Snowflake Secure Data Share (no data copying)
- Creates a shared database visible in PRE-PROD account

**Key Configuration:**
- Share name: `ALATION_ANALYTICS_SHARE` (example)
- Permissions: Read-only

**Questions to Ask:**
- Is the Snowflake account configured to receive the share?
- Who has access to the shared database?
- Is there a cost implication for data share usage?

---

### Component 4: Governance Database

**What Happens:**
- Stores classification metadata locally in Snowflake
- Table structure:
  ```sql
  TABLE: CLASSIFICATION_TABLE
  - DATABASE_NAME
  - SCHEMA_NAME  
  - TABLE_NAME
  - COLUMN_NAME
  - SECURITY_CLASSIFICATION_CODE
  - PII_FLAG
  - PCI_FLAG
  - Other compliance fields
  ```

**Key Configuration:**
- Database: `GOVERNANCE_DB` or `METADATA_DB`
- Access: Read-only for most users, write access for ETL process

**Questions to Ask:**
- Where will the Governance Database be located?
- Who has write access to update classifications?
- Is there a backup/versioning strategy for classification changes?

---

### Component 5: Apply Tags Using DBT

**What Happens:**
- DBT post-hooks execute after table creation
- Read from Governance Database
- Apply Snowflake tags to columns:
  ```sql
  ALTER TABLE schema.table_name 
  MODIFY COLUMN column_name 
  SET TAG SECURITY_CLASSIFICATION_CODE = 'HIGHLY_CONFIDENTIAL';
  ```

**Two Scenarios:**

**Scenario 1: Daily DBT Jobs**
- Tags applied automatically in post-hook
- Happens every time DBT runs

**Scenario 2: Non-Daily DBT Jobs**
- Separate tag refresh job runs daily
- Ensures tags stay current even if DBT doesn't run

**Key Configuration:**
- DBT macro: `apply_classification_tags()`
- Post-hook in DBT models
- Separate tag refresh job (optional)

**Questions to Ask:**
- Are DBT jobs running daily, or do you need a separate tag refresh process?
- Who maintains the DBT macros?
- How do you handle errors during tag application?
- What happens if Governance DB is unavailable?

---

### Component 6 & 7: Masking Policies in DEV & SYST

**What Happens:**
- Snowflake masking policies attached to tags
- Policy checks user's role and tag value
- Returns masked/hashed/clear data based on policy

**Example Masking Policy:**
```sql
CREATE OR REPLACE MASKING POLICY mask_highly_confidential 
AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('LANDING_DEV_DEVELOPER_HC', 'ADMIN') 
      THEN val  -- Show clear
    ELSE '***MASKED***'  -- Mask for everyone else
  END;
```

**Questions to Ask:**
- Are masking policies already created, or do they need development?
- What masking format is preferred? (e.g., `***MASKED***`, `NULL`, `XXXX1234` for PANs)
- How are exceptions handled (e.g., audit team temporary access)?
- Are masking policies tested before PROD deployment?

---

### Components 8-16: PROD Environment Flow

**Same pattern as PRE-PROD but for PPTE/PROD:**
- Component 8: Promote Alation Catalog Sets/Data Sources to PROD config
- Component 9: Scan PPTE
- Component 10: Sync to Alation Analytics
- Component 11: Secure share to PROD account
- Component 12: Governance DB in PROD
- Component 13: Apply tags in PPTE
- Component 14: Masking in PPTE
- Component 15: Masking in PROD (inherit from PPTE)
- Component 16: Compliance-only scan of PROD

**Questions to Ask:**
- Is the Alation promotion process automated or manual?
- How long does promotion from PRE-PROD to PROD configuration take?
- Who approves changes to PROD Catalog Sets?

---

## ❓ CRITICAL QUESTIONS TO ASK USERS

### 🔹 PROJECT SCOPE & READINESS

#### Current State
1. **Do you already have Alation deployed and configured?**
   - If no: Timeline for Alation implementation?
   - If yes: Version? License type? Alation Analytics enabled?

2. **Is Snowflake already in use for data warehousing?**
   - Which databases/schemas exist?
   - Are there existing tags or masking policies?

3. **Do you have a DBT framework deployed?**
   - Version of DBT?
   - Who maintains DBT code?
   - Is there a CI/CD pipeline?

4. **What is your current approach to data masking?**
   - Manual scripts?
   - No masking currently?
   - Different tool?

#### Stakeholder Alignment
5. **Who are the key stakeholders?**
   - Data Engineering lead?
   - Data Governance/DM&G team?
   - Security/Risk team?
   - Architecture team?

6. **Who will be the Data Stewards in Alation?**
   - How many stewards per domain?
   - Are they trained in data classification?

7. **Who approves role assignments for data access?**
   - Automated approval workflow?
   - Manual approval?

---

### 🔹 ALATION CONFIGURATION

#### Catalog Sets
8. **Have Catalog Sets been created yet?**
   - How many Catalog Sets exist?
   - What regex patterns are used?
   - Are they tested and validated?

9. **How often should Catalog Sets be updated?**
   - Weekly? Monthly? As-needed?
   - Who reviews and approves changes?

10. **How are exceptions handled?**
    - What if Alation misclassifies a column?
    - Process for manual override?

#### Data Sources
11. **How many Snowflake Data Sources are configured in Alation?**
    - Separate for PRE-PROD and PROD?
    - Which databases are scanned?

12. **What is the scanning frequency?**
    - Daily? Weekly? On-demand?
    - Full scan or incremental?

13. **Are service accounts set up for Alation to access Snowflake?**
    - Credentials rotated?
    - Least privilege access?

---

### 🔹 SNOWFLAKE CONFIGURATION

#### Accounts & Environments
14. **How many Snowflake accounts do you have?**
    - PRE-PROD account?
    - PROD account?
    - Separate accounts or databases within one account?

15. **What environments exist within each account?**
    - DEV, SYST, PPTE, PROD?
    - Any others (UAT, QA)?

16. **Is there a strict code promotion process?**
    - DEV → SYST → PPTE → PROD?
    - Can hotfixes bypass this flow?

#### Governance Database
17. **Where will the Governance Database be located?**
    - Separate database or schema within existing DB?
    - Naming convention?

18. **Who has write access to the Governance Database?**
    - Only ETL service accounts?
    - Data governance team for manual corrections?

19. **How are classification changes versioned?**
    - Audit trail of changes?
    - Ability to roll back?

#### Secure Data Shares
20. **Are Snowflake Secure Data Shares already configured?**
    - From Alation Analytics to PRE-PROD account?
    - From Alation Analytics to PROD account?

21. **Who manages the data shares?**
    - Alation team?
    - Snowflake admin?

#### Tags & Masking Policies
22. **Do Snowflake tags already exist?**
    - If yes: Can we reuse or need to create new?
    - Naming convention for tags?

23. **Are masking policies already written?**
    - For each classification level?
    - Tested and validated?

24. **What masking formats are required?**
    - Full masking (`***MASKED***`)?
    - Partial masking (e.g., `XXXX1234` for PANs)?
    - Hashing (e.g., SHA-256)?

---

### 🔹 DBT CONFIGURATION

#### Current Setup
25. **What version of DBT is in use?**
    - DBT Cloud or DBT Core?
    - Version number?

26. **Are DBT jobs running daily?**
    - If no: How often?
    - Do you need a separate tag refresh job?

27. **Do you use post-hooks in DBT already?**
    - Familiar with post-hook syntax?
    - Existing macros to reference?

#### Tag Application
28. **Should tags be applied immediately after table creation or in a separate process?**
    - Real-time tagging?
    - Batch tagging?

29. **What happens if tag application fails?**
    - Retry logic?
    - Alerts/notifications?

30. **Who is responsible for maintaining DBT macros?**
    - Data engineering team?
    - Platform team?

---

### 🔹 DATA CLASSIFICATION

#### Classification Levels
31. **Are the 4 classification levels acceptable?**
    - Public, Private, Confidential, Highly Confidential
    - Need additional levels?

32. **Is "Unclassified = Highly Confidential" acceptable?**
    - Safe default approach
    - Or too restrictive?

33. **How should conflicts be resolved?**
    - If a column matches multiple Catalog Sets with different classifications?
    - Take the highest (most restrictive)?

#### Keys Handling (BK, PK, FK)
34. **How should Business Keys be identified?**
    - Manual tagging in Alation?
    - Naming convention (e.g., `customer_id_pk`)?
    - DBT YAML constraints?

35. **Is hashing acceptable for keys?**
    - Or do some use cases require clear keys?
    - Which hashing algorithm (SHA-256, MD5)?

36. **Are there keys that should NOT be hashed?**
    - Exceptions?

---

### 🔹 ROLE-BASED ACCESS CONTROL

#### Roles & Personas
37. **How many Landing developers will there be?**
    - Small, trusted group?
    - Need for background checks?

38. **What are the Subject Area zones?**
    - Finance, Marketing, Risk, etc.?
    - Separate roles per zone?

39. **Do you need a "Restricted Access" role in Landing?**
    - For highly sensitive sources (fraud, EAP, investigations)?
    - How many restrictions?

40. **Will there be a Transform Database for developers?**
    - Sandbox environment?
    - Unmasked access to their own schema?

#### Access Approval
41. **Who approves role assignments?**
    - Manager approval?
    - Data owner approval?
    - Automated or manual?

42. **How long does role provisioning take?**
    - Same-day? 1-2 days?
    - Self-service or ticketing system?

43. **How are access reviews conducted?**
    - Quarterly? Annually?
    - Automated reports?

---

### 🔹 REGULATORY & COMPLIANCE

#### PCI DSS
44. **Where is PAN (credit card) data stored?**
    - Is it tokenized upstream before Snowflake?
    - Or does Snowflake receive raw PANs?

45. **Is tokenization handled outside this solution?**
    - Assumption: Yes (out of scope)
    - If no: Need to add tokenization logic

46. **Who is the PCI compliance officer?**
    - How are PCI audits conducted?

#### PII / Privacy
47. **What constitutes PII in your organization?**
    - Name, address, email, phone?
    - Government IDs (Tax ID, Medicare)?

48. **Are there regional privacy laws to consider?**
    - Privacy Act 2020 (New Zealand)?
    - GDPR (if EU data)?
    - CCPA (if California residents)?

49. **What is the data retention policy?**
    - How long is PII kept?
    - Automated deletion process?

#### APRA (Australian Prudential Regulation Authority)
50. **Are you subject to APRA regulations?**
    - CPG 235 (Data Risk Management)?
    - CPS 234 (Information Security)?

51. **How are data quality metrics tracked?**
    - Automated reports?
    - Who reviews?

---

### 🔹 OPERATIONAL CONSIDERATIONS

#### Monitoring & Alerts
52. **What monitoring is in place?**
    - Alation scan failures?
    - Alation Analytics sync failures?
    - Tag application errors?

53. **Who gets alerted when something fails?**
    - On-call team?
    - Email distribution list?

54. **What is the SLA for resolving classification issues?**
    - Same-day? 1 business day?

#### Performance
55. **How large is your Snowflake environment?**
    - Number of databases/schemas/tables?
    - Will Alation scans cause performance issues?

56. **Is the 24-hour sync frequency acceptable?**
    - Or do you need near-real-time?

57. **How will you test at scale?**
    - Load testing with large datasets?
    - Simulated user access patterns?

#### Change Management
58. **How are changes to Catalog Sets promoted?**
    - DEV → PROD promotion process?
    - Approval required?

59. **What happens if a classification changes in PROD?**
    - Immediate effect or scheduled?
    - Impact analysis required?

60. **How do you handle emergency access?**
    - Break-glass procedure for urgent access?
    - Audit trail?

---

### 🔹 FUTURE ENHANCEMENTS

#### Production Data in Non-Prod
61. **Do you plan to use PROD data in DEV/SYST?**
    - Timeline for this enhancement?
    - Additional masking required?

62. **Will you integrate with SecurDPS?**
    - For data-value-based classification (not just metadata)?
    - Timeline?

#### Other Integrations
63. **Will you scan inbound data shares from other sources?**
    - External vendors?
    - Other business units?

64. **Do you need integration with other tools?**
    - ServiceNow for ticketing?
    - Power BI for reporting?
    - Collibra for data governance?

---

### 🔹 TRAINING & SUPPORT

#### User Training
65. **Who needs training on Alation?**
    - Data stewards?
    - Developers?
    - Consumers?

66. **Who needs training on DBT macros?**
    - Data engineers?
    - Analytics engineers?

67. **What is the rollout plan?**
    - Pilot with one subject area?
    - Big-bang across all zones?

#### Documentation
68. **What documentation exists today?**
    - Alation user guides?
    - Snowflake role definitions?
    - DBT standards?

69. **Who will maintain documentation going forward?**
    - Dedicated technical writer?
    - Engineering team?

#### Support
70. **Who provides Level 1 support?**
    - Help desk?
    - Data engineering team?

71. **What are the escalation paths?**
    - Level 2: Platform team?
    - Level 3: Vendor support (Alation, Snowflake)?

72. **Are support SLAs defined?**
    - Response time?
    - Resolution time?

---

## ✅ IMPLEMENTATION CHECKLIST

### Phase 1: Foundation Setup (Weeks 1-2)

#### Alation
- [ ] Alation instance deployed and accessible
- [ ] Alation Analytics enabled
- [ ] Service accounts created for Snowflake connectivity
- [ ] PRE-PROD Data Sources configured
- [ ] PROD Data Sources configured
- [ ] Catalog Sets created and tested
- [ ] Custom field `SECURITY_CLASSIFICATION_CODE` added to column templates
- [ ] Data stewards identified and trained

#### Snowflake
- [ ] PRE-PROD account setup
- [ ] PROD account setup
- [ ] Governance Database created in both accounts
- [ ] `CLASSIFICATION_TABLE` schema designed and deployed
- [ ] Service accounts for Alation Analytics data share created
- [ ] Secure Data Shares configured (Alation Analytics → Snowflake)
- [ ] Snowflake roles defined (Landing Developer, Subject Area Developer, etc.)

#### DBT
- [ ] DBT framework deployed
- [ ] Macro for tag application written (`apply_classification_tags()`)
- [ ] Post-hooks added to DBT models
- [ ] Tag refresh job created (if needed for non-daily jobs)
- [ ] CI/CD pipeline configured for DBT

---

### Phase 2: Classification & Tagging (Weeks 3-4)

#### Alation Configuration
- [ ] Initial scan of DEV databases completed
- [ ] Catalog Sets applied to columns
- [ ] Spot-check accuracy of auto-classifications
- [ ] Manual corrections applied where needed
- [ ] Alation → Alation Analytics sync verified (24hr cycle)

#### Snowflake Integration
- [ ] Secure Data Share from Alation Analytics validated
- [ ] Data visible in Governance Database
- [ ] DBT post-hook tested in DEV
- [ ] Tags applied successfully to sample tables
- [ ] Tags visible in Snowflake metadata

---

### Phase 3: Masking Policies (Weeks 5-6)

#### Policy Creation
- [ ] Masking policy for Public classification
- [ ] Masking policy for Private classification
- [ ] Masking policy for Confidential classification
- [ ] Masking policy for Highly Confidential classification
- [ ] Masking policy for Unclassified (default to Highly Confidential)
- [ ] Hashing policy for Business Keys (BK)
- [ ] Hashing policy for Primary Keys (PK)
- [ ] Hashing policy for Foreign Keys (FK)

#### Policy Assignment
- [ ] Policies assigned to tags
- [ ] Role-based conditions tested
- [ ] Landing Developer role can see Highly Confidential
- [ ] Subject Area Developer (HC) role can see Highly Confidential
- [ ] Subject Area Developer (C) role cannot see Highly Confidential
- [ ] Consumers see only Public/Private data

---

### Phase 4: SYST Environment (Week 7)

- [ ] Code promoted from DEV to SYST
- [ ] Classifications inherited correctly
- [ ] Tags re-applied in SYST
- [ ] Masking policies enforced
- [ ] User access tested

---

### Phase 5: PPTE & PROD (Weeks 8-10)

#### Alation Promotion
- [ ] Catalog Sets promoted to PROD configuration
- [ ] Data Sources promoted to PROD configuration
- [ ] PPTE scan initiated
- [ ] Classifications validated

#### Snowflake PROD
- [ ] Secure Data Share to PROD account configured
- [ ] Governance DB in PROD populated
- [ ] Tags applied in PPTE
- [ ] Masking policies deployed to PROD
- [ ] PROD scanned for compliance (read-only)

#### Code Promotion
- [ ] PPTE → PROD promotion tested
- [ ] Classifications carry over correctly
- [ ] Masking enforced in PROD

---

### Phase 6: Monitoring & Validation (Week 11)

- [ ] Alation scan monitoring dashboards created
- [ ] Alation Analytics sync alerts configured
- [ ] Tag application error alerts configured
- [ ] Masking policy audit queries created
- [ ] Access review process defined
- [ ] Compliance reporting (PCI, PII, APRA) validated

---

### Phase 7: Training & Handover (Week 12)

- [ ] Data steward training completed
- [ ] Developer training on DBT macros completed
- [ ] Consumer training on data access completed
- [ ] Documentation finalized
- [ ] Runbooks created
- [ ] Support team trained
- [ ] Go-live readiness review completed

---

## 👥 ROLE-BASED ACCESS MATRIX

### PRE-PROD Account (DEV & SYST)

| Persona | Role Name | Public | Private | Confidential | Highly Confidential | Unclassified |
|---------|-----------|--------|---------|--------------|---------------------|--------------|
| **Landing Developer (General)** | `Landing_dev_developer_HC` | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear |
| **Landing Developer (Restricted)** | `Landing_dev_[RSTSRC]_developer_HC` | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear |
| **Subject Area Developer (HC)** | `[Zone]_dev_developer_HC` | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear |
| **Subject Area Developer (C)** | `[Zone]_dev_developer_C` | ✅ Clear | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked |
| **Subject Area Developer (P)** | `[Zone]_dev_developer_P` | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked | ❌ Masked |
| **Foundation Developer (C)** | `[Zone]_dev_developer_C` | ✅ Clear | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked |
| **Foundation Developer (P)** | `[Zone]_dev_developer_P` | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked | ❌ Masked |
| **Curated Developer (P)** | `[Zone]_dev_developer_P` | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked | ❌ Masked |
| **Transform Developer** | `Transform_dev_developer` | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear (own schema only) |
| **Consumer** | `Consumer_role` | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked | ❌ Masked |

**Legend:**
- ✅ Clear = Can see data in the clear
- ❌ Masked = Data is masked/hashed
- [Zone] = Subject area name (e.g., Finance, Marketing, Risk)
- [RSTSRC] = Restricted source name (e.g., FRAUD, EAP, INVEST)

### PROD Account (PPTE & PROD)

| Persona | Role Name | Public | Private | Confidential | Highly Confidential | Unclassified |
|---------|-----------|--------|---------|--------------|---------------------|--------------|
| **Landing Developer (General)** | `Landing_ppte_developer_HC` | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear |
| **Landing Developer (Restricted)** | `Landing_ppte_[RSTSRC]_developer_HC` | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear |
| **Subject Area Developer (HC)** | `[Zone]_ppte_developer_HC` | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear | ✅ Clear |
| **Subject Area Developer (C)** | `[Zone]_ppte_developer_C` | ✅ Clear | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked |
| **Consumer (PROD)** | `Consumer_prod_role` | ✅ Clear | ✅ Clear | ❌ Masked | ❌ Masked | ❌ Masked |

---

## 🔄 DATA FLOW & INTEGRATION POINTS

### Daily Classification Refresh Flow

```
Day 1 - 00:00: Alation Scan Completes
             ↓
Day 1 - 01:00: Alation → Alation Analytics ETL Starts
             ↓
Day 1 - 02:00: Alation Analytics Updated
             ↓
Day 1 - 02:05: Secure Data Share Auto-Refreshes
             ↓
Day 1 - 02:10: Snowflake Governance DB Sees New Data
             ↓
Day 1 - 03:00: DBT Job Runs (if scheduled)
             ↓
Day 1 - 03:15: Tags Applied to New/Changed Columns
             ↓
Day 1 - 03:20: Masking Policies Active
             ↓
Day 1 - 08:00: Users See Updated Masking
```

### Code Promotion Flow

```
Developer → Commits Code to Git
         ↓
CI/CD Pipeline → Deploys to DEV
         ↓
DBT Post-Hook → Applies Tags in DEV
         ↓
Testing → Validated in DEV
         ↓
Code Promotion → Deployed to SYST
         ↓
DBT Post-Hook → Re-applies Same Tags in SYST
         ↓
Testing → Validated in SYST
         ↓
Code Promotion → Deployed to PPTE
         ↓
DBT Post-Hook → Applies Tags in PPTE (from PPTE scan)
         ↓
Testing → Validated in PPTE
         ↓
Code Promotion → Deployed to PROD
         ↓
DBT Post-Hook → Re-applies Same Tags in PROD
         ↓
Production → Live
```

---

## 📜 REGULATORY & COMPLIANCE REQUIREMENTS

### Summary of Key Requirements

| ID | Requirement | Regulation | How This Solution Addresses It |
|----|-------------|------------|-------------------------------|
| 1 | Classify data by criticality and sensitivity | APRA CPG 235 | Alation auto-classifies using Catalog Sets |
| 2 | Desensitise data when extending usage | APRA CPG 235 | Masking policies enforce based on role |
| 9 | Highly Confidential data not in non-prod unless masked | BNZ GIRP | Masking enforced in DEV/SYST/PPTE |
| 13 | Card numbers masked (XXXX XXXX XXXX 1234) | BNZ PCI Guidance | Masking policy for PAN fields |
| 16 | Cardholder auth data (CVV, PIN) not stored post-auth | GIRP | Assumed handled upstream (out of scope) |
| 17 | PANs unreadable when displayed | GIRP | Masking policy truncates to XXXX1234 |
| 18 | PANs indecipherable when stored | PCI DSS 3.5 | Masking + hashing policies |
| 22 | Sensitive auth data not stored after auth | PCI DSS 3.3 | Assumed handled upstream (out of scope) |
| 23 | PAN secured, access restricted | PCI DSS 3.4 | Masking policies + role-based access |
| 24 | Personal info protected by access controls | Privacy Act 2020 | RBAC + masking enforced |

### Compliance Reporting

**Questions to Ask:**
- Who generates compliance reports?
- How often (monthly, quarterly)?
- What format (CSV, PDF, dashboard)?
- Who receives the reports (audit team, regulators)?

**Suggested Reports:**
1. **Data Classification Coverage**
   - % of columns classified
   - % unclassified
   - Top unclassified tables

2. **PII/PCI Inventory**
   - All columns with PII flag
   - All columns with PCI flag
   - Masking status

3. **Access Review**
   - Users with Highly Confidential access
   - Last access date
   - Access justification

4. **Masking Policy Audit**
   - Columns with masking applied
   - Columns without masking (should be Public only)
   - Exceptions granted

---

## 🚨 RISK & MITIGATION

### Key Risks

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| **Alation misclassifies sensitive data as Public** | High (data exposure) | Medium | Manual review by data stewards, SecurDPS validation in future |
| **24-hour sync delay causes stale classifications** | Medium | Low | Monitor sync job, manual trigger available |
| **DBT post-hook fails to apply tags** | High (data unmasked) | Medium | Default to "Unclassified" = masked, error alerts |
| **User assigned wrong role** | High (unauthorized access) | Medium | Approval workflow, quarterly access reviews |
| **Keys masked instead of hashed** | Medium (developer productivity) | Low | Clear BK/PK/FK identification process |
| **Catalog Set conflict (duplicate classifications)** | Medium | Medium | Ranking rule (most restrictive wins), Alation UI alerts |
| **PROD hotfix bypasses PPTE** | Medium (classifications not applied) | Low | Strict code promotion policy, exceptions documented |

---

## 📞 SUPPORT & ESCALATION

### Support Tiers

| Tier | Responsible Team | Response Time | Resolution Time | Scope |
|------|------------------|---------------|-----------------|-------|
| **Tier 1** | Help Desk / Data Engineering | 1 business hour | 4 business hours | User access requests, basic questions |
| **Tier 2** | Platform Team / Data Governance | 4 business hours | 1 business day | Classification issues, tag errors |
| **Tier 3** | Vendor Support (Alation/Snowflake) | 1 business day | 3-5 business days | Platform bugs, performance issues |

### Escalation Contacts

**Questions to Ask:**
- Who is the escalation contact for Alation issues?
- Who is the escalation contact for Snowflake issues?
- Who is the escalation contact for DBT issues?
- Is there a 24/7 on-call rotation for production issues?

---

## 🎓 TRAINING MATERIALS NEEDED

### For Data Stewards (Alation)
1. How to create and manage Catalog Sets
2. How to review and approve auto-classifications
3. How to manually override incorrect classifications
4. How to resolve Catalog Set conflicts
5. How to promote configurations to PROD

### For Developers (Snowflake + DBT)
1. Understanding data classifications and their impact
2. How to request appropriate role access
3. How DBT post-hooks apply tags
4. What to do if tags aren't applied correctly
5. How to work with hashed keys vs masked data

### For Consumers (End Users)
1. Understanding what data they can see based on role
2. How to request additional access if needed
3. Why some data appears masked
4. Who to contact for support

---

## 🏁 SUCCESS CRITERIA

### Go-Live Criteria
- [ ] All Alation Catalog Sets reviewed and approved by data stewards
- [ ] 95%+ of columns in scope are classified (not Unclassified)
- [ ] All masking policies tested and validated
- [ ] All roles created and access tested
- [ ] DBT post-hooks successfully applied in all environments
- [ ] No open critical or high-severity bugs
- [ ] Training completed for all user groups
- [ ] Documentation finalized and published
- [ ] Support team ready with runbooks
- [ ] Compliance reporting validated

### Ongoing KPIs
1. **Classification Coverage:** % of columns classified (target: 95%+)
2. **Sync Success Rate:** % of Alation → Analytics syncs successful (target: 99%+)
3. **Tag Application Success:** % of DBT jobs with successful tag application (target: 99%+)
4. **Access Request Turnaround:** Time to provision new role (target: <1 business day)
5. **Support Tickets:** Number of classification-related support tickets (trend down over time)
6. **Compliance Audit Pass Rate:** % of compliance checks passed (target: 100%)

---

## 📝 FINAL NOTES

This implementation is **complex** but highly **scalable and automated** once established.

**Key Success Factors:**
1. ✅ **Executive sponsorship** - Data governance is a cultural change
2. ✅ **Data steward engagement** - They must maintain Catalog Sets
3. ✅ **Developer buy-in** - They must understand why masking exists
4. ✅ **Strict code promotion** - DEV→SYST→PPTE→PROD flow enforced
5. ✅ **Ongoing monitoring** - Classifications drift over time without oversight

**Common Pitfalls to Avoid:**
1. ❌ Letting Catalog Sets become stale (no longer match new data patterns)
2. ❌ Granting too many "Highly Confidential" roles (defeats the purpose)
3. ❌ Allowing hotfixes to bypass code promotion (breaks classification flow)
4. ❌ Not testing masking thoroughly before PROD (data exposure risk)
5. ❌ Inadequate training (users won't understand why they can't see data)

---

**Good luck with your implementation! 🚀**

For questions, refer to the original 68-page design document or contact the document author: Bradley Freedman.
