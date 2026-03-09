Strategic Data Masking & Classification – High Level Design
1. Overview

This solution automates data masking enforcement in Snowflake based on data classification metadata.

The Platform team will develop reusable dbt macros that apply masking policies automatically based on classification information. These macros will be maintained in the Platform repository and shared with zone repositories.

Zone repositories will import and execute these macros, which will apply masking policies to tables and columns based on the classification defined in the governance system.

This approach ensures consistent and centralized data protection across all data zones.

2. Objective

The objective of this solution is to:

Standardize the application of data masking policies

Centralize masking logic within the Platform repository

Enable zone repositories to reuse masking macros

Automatically enforce masking based on data classification

Ensure consistent data governance and security controls

3. Current State (As-Is)

Currently, data masking enforcement requires manual or project-specific implementations.

Challenges include:

Masking logic implemented separately across projects

Lack of centralized governance for masking logic

Manual effort required to apply masking policies

Inconsistent implementation across data zones

4. Target State (To-Be)

The proposed design introduces a centralized masking framework.

Key improvements:

Masking macros are developed and maintained in the Platform repository

Zone repositories import the platform macros

Masking policies are applied automatically based on classification

Standardized masking logic across all data zones

Reduced manual effort and improved governance

5. High Level Architecture

The solution consists of the following components:

1. Alation (Data Catalog)
Maintains data classification metadata for datasets.

2. Snowflake
Stores the data tables and enforces masking policies.

3. Platform Repository (dbt Macros)
Contains reusable macros responsible for applying tags and masking policies.

4. Zone Repositories
Data product repositories that import platform macros and execute them during dbt runs.

5. Orchestration (Airflow)
Schedules and executes dbt pipelines across environments.

6. High Level Flow

The overall process works as follows:

Data classification is defined in Alation.

Classification metadata is available in Snowflake and represents the sensitivity level of datasets.

The Platform repository provides reusable dbt macros that implement the logic for applying masking policies.

Zone repositories import these macros using dbt dependency mechanisms.

During dbt execution in a zone repository:

The masking macros are executed

Macros evaluate classification metadata

Appropriate masking policies are applied automatically to the relevant tables and columns.

Snowflake enforces masking policies at query runtime based on user roles and access privileges.

7. Platform Macro Framework

The Platform repository provides reusable macros responsible for:

Reading classification information

Determining applicable masking policies

Generating SQL statements to apply masking policies

Applying masking policies in Snowflake

These macros are designed to be reusable across multiple data zones and environments.

8. Zone Repository Integration

Each zone repository integrates with the Platform repository by importing the shared macros.

During pipeline execution:

dbt loads macros from the Platform repository

The masking macro is executed

Masking policies are applied automatically

This ensures that all data zones follow the same governance standards without implementing masking logic independently.

9. Orchestration

The execution of dbt pipelines is orchestrated using Airflow.

Airflow is responsible for:

Triggering dbt runs

Executing the masking macros as part of the pipeline

Ensuring masking policies are applied consistently across environments

10. Security and Governance

The design ensures that:

Masking logic is centralized in the Platform repository

Data zones cannot modify core masking logic

Masking policies are applied consistently across datasets

Sensitive data is protected according to defined classifications

11. Benefits

This design provides several advantages:

Centralized governance of masking policies

Reusable masking framework across zones

Reduced manual implementation effort

Consistent enforcement of security policies

Scalable approach for enterprise data governance
