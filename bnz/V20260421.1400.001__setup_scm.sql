

CREATE OR REPLACE TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG ALLOWED_VALUES 'AIPCUST','CUSTENG','CUST','LOANS','PTP','RISK', 'FINCRIME','FINANCE','CUSTINTERACT','COLLEAGUE','PTP','GOVERNANCE';
CREATE OR REPLACE TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE ALLOWED_VALUES 'Public','Confidential','Highly Confidential','Unclassified','Private';
CREATE OR REPLACE TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.ANCHOR_TAG;
CREATE OR REPLACE TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.BUSINESS_KEY_FLAG ALLOWED_VALUES 'Y','N';
CREATE OR REPLACE TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.PRIMARY_KEY_FLAG ALLOWED_VALUES 'Y','N';




--SENSITIVE_DATA_MASK_BOOLEAN

CREATE OR REPLACE MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_BOOLEAN
AS (VAL BOOLEAN) RETURNS BOOLEAN ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF roles → NULL for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified now correctly falls to ELSE NULL
    --              for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE NULL

END;

--SENSITIVE_DATA_MASK_DATE

CREATE OR REPLACE MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_DATE
AS (VAL DATE) RETURNS DATE ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF roles → '0001-01-01' for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified now correctly falls to ELSE '0001-01-01'::DATE
    --              for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE '0001-01-01'::DATE

END;

--SENSITIVE_DATA_MASK_NUMBER

CREATE OR REPLACE MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_NUMBER
AS (VAL NUMBER) RETURNS NUMBER ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF roles → -1 for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified is now correctly handled by Condition 1 (_HC only)
    --              and falls to ELSE -1 for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE -1

END;

--SENSITIVE_DATA_MASK_STRING

CREATE OR REPLACE MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_STRING
AS (VAL VARCHAR) RETURNS VARCHAR ->
CASE
    -- Condition 1: User has HC access (sees all: Unclassified, HC, Confidential)
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|ALAMETADATAEXTRACTION).*'
                )
            )
        )
        OR
        -- Condition 2: User has CONF access (sees Confidential only)
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_CONF.*'
                )
            )
        )
    THEN VAL
    
    -- Condition 3: User doesn't have access AND column is PK/BK -> Apply HASH masking
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.PRIMARY_KEY_FLAG') = 'Y'
            OR
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.BUSINESS_KEY_FLAG') = 'Y'
        )
        AND
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Unclassified', 'Highly Confidential', 'Confidential')
    THEN SHA2(VAL, 256)
    
    -- Condition 4: User doesn't have access AND regular column -> Apply STRING masking
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Unclassified', 'Highly Confidential', 'Confidential')
    THEN '**MASKED**'
    
    -- Condition 5: Public/Private or no classification -> Show plain text
    ELSE VAL
END;

--SENSITIVE_DATA_MASK_TIMESTAMP

CREATE OR REPLACE MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_TIMESTAMP
AS (VAL TIMESTAMP_LTZ) RETURNS TIMESTAMP_LTZ ->
CASE
    -- Condition 1: HC Access - Plain text for ALL classifications
    -- _HC, SVC, ALAMETADATAEXTRACTION roles
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
                ('Unclassified', 'Highly Confidential', 'Confidential')
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_HC.*|.*SVC\\w+(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    '|ALAMETADATAEXTRACTION).*'))
        )
    THEN VAL

    -- Condition 2: CONF Access - Plain text ONLY for Confidential
    --              _CONF roles → '0001-01-01' for Highly Confidential & Unclassified
    WHEN
        (
            SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') = 'Confidential'
            AND
            REGEXP_LIKE(
                ARRAY_TO_STRING(ARRAY_CONSTRUCT(CURRENT_ROLE(), PARSE_JSON(CURRENT_SECONDARY_ROLES()):roles), ','),
                CONCAT('.*(',
                    SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG'),
                    ')\\w+_CONF.*'))
        )
    THEN VAL

    -- Condition 3: REMOVED "Unclassified = everyone sees"
    --              Unclassified now correctly falls to ELSE '0001-01-01'::TIMESTAMP
    --              for _CONF and base developer roles

    -- Condition 4: Private/Public - No masking for everyone (return as-is)
    WHEN
        SYSTEM$GET_TAG_ON_CURRENT_COLUMN('GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE') IN
            ('Private', 'Public')
    THEN VAL

    -- Default: Mask all other cases (Confidential, Highly Confidential, Unclassified with no matching role)
    ELSE TO_TIMESTAMP_LTZ('1900-01-01 00:00:00')

END;

-- Apply Masking policy to anchor tag 
 ALTER TAG IF EXISTS GOVERNANCE__${env}.GOVERNANCE_TAGGING.ANCHOR_TAG SET
MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_STRING
  , MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_NUMBER
  , MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_BOOLEAN
  , MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_TIMESTAMP
  , MASKING POLICY GOVERNANCE__${env}.GOVERNANCE_MASKING.SENSITIVE_DATA_MASK_DATE;
  

--Apply tags to  read role
GRANT APPLY ON TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.SECURITY_CLASSIFICATION_CODE   TO ROLE BDH_SF_SVC_AR_GOVERNANCE_${env}_READ;
GRANT APPLY ON TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.BUSINESS_KEY_FLAG   TO ROLE BDH_SF_SVC_AR_GOVERNANCE_${env}_READ;
GRANT APPLY ON TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.ANCHOR_TAG   TO ROLE BDH_SF_SVC_AR_GOVERNANCE_${env}_READ;
GRANT APPLY ON TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.PRIMARY_KEY_FLAG   TO ROLE BDH_SF_SVC_AR_GOVERNANCE_${env}_READ;
GRANT APPLY ON TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG  TO ROLE BDH_SF_SVC_AR_GOVERNANCE_${env}_READ;



ALTER DATABASE  GOVERNANCE__LOGGING__${env} SET TAG GOVERNANCE__${env}.GOVERNANCE_TAGGING.ZONE_TAG = 'GOVERNANCE';


