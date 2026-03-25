CREATE OR REPLACE MASKING POLICY GOVERNANCE__PREPROD.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_NUMBER
AS (VAL NUMBER) RETURNS NUMBER ->
CASE
    -- ✅ HC Role → Plain text for ALL classifications (Public, Private, Confidential, Highly Confidential, Unclassified)
    WHEN
        REGEXP_LIKE(
            ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
            CONCAT('.*(',
                SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                '\\w*_HC',
                '|CUST',
                '|SVC\\w+',
                '|ALAMETADATAEXTRACTION).*')
        )
    THEN VAL

    -- ✅ CONF Role + CUST → Plain text ONLY for Public, Private, Confidential → -1 for Highly Confidential & Unclassified
    WHEN
        REGEXP_LIKE(
            ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
            CONCAT('.*(',
                SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                '\\w*_CONF',
                '|CUST).*')
        )
        AND
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE')
            IN ('Unclassified', 'Confidential')
    THEN VAL

    -- ✅ Base developer Role → Plain text ONLY for Public, Private → -1 for rest
    WHEN
        REGEXP_LIKE(
            ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
            CONCAT('.*',
                SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.ZONE_TAG'),
                '\\w*_developer.*')
        )
        AND
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE')
            NOT IN ('Confidential', 'Highly Confidential')
    THEN VAL

    -- ❌ Classified data with no matching role → Mask with -1
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__PREPROD.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE')
            IN ('Unclassified', 'Highly Confidential', 'Confidential')
    THEN -1

    ELSE VAL
END;
