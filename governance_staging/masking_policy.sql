ALTER MASKING POLICY GOVERNANCE__PREPROD.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_NUMBER
SET BODY ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, CUST, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF and CUST roles → -1 for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified is now correctly handled by Condition 1 (_HC only)
    --              and falls to ELSE -1 for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE -1

END;

________________________

CREATE OR REPLACE MASKING POLICY GOVERNANCE__PREPROD.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_BOOLEAN
AS (VAL BOOLEAN) RETURNS BOOLEAN ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, CUST, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF and CUST roles → NULL for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified now correctly falls to ELSE NULL
    --              for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE NULL

END;

________________________

CREATE OR REPLACE MASKING POLICY GOVERNANCE__PREPROD.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_DATE
AS (VAL DATE) RETURNS DATE ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, CUST, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF and CUST roles → '0001-01-01' for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified now correctly falls to ELSE '0001-01-01'::DATE
    --              for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE '0001-01-01'::DATE

END;

____________________________

CREATE OR REPLACE MASKING POLICY GOVERNANCE__PREPROD.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_TIMESTAMP
AS (VAL TIMESTAMP_NTZ) RETURNS TIMESTAMP_NTZ ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, CUST, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF and CUST roles → '0001-01-01' for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|CUST)\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified now correctly falls to ELSE '0001-01-01'::TIMESTAMP
    --              for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE '0001-01-01'::TIMESTAMP

END;
