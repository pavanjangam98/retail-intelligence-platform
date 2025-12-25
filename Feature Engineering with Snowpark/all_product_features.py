# ---------------------------------------------------------
# Imports (from snowpark_features_notebook1.py)
# ---------------------------------------------------------
from snowflake.snowpark.functions import col, udf, array_intersection, array_size
from snowflake.snowpark.types import StringType, FloatType, IntegerType
from snowflake.snowpark.functions import abs as sf_abs

print("Imports loaded.")

# ---------------------------------------------------------
# Jaccard Similarity UDF (from snowpark_features_notebook2.py)
# ---------------------------------------------------------
@udf(
    name="jaccard_similarity",
    return_type=FloatType(),
    input_types=[StringType(), StringType()],
    is_permanent=True,
    stage_location="@RETAIL_INTELLIGENCE_DB.RAW.RETAIL_STAGE",
    replace=True
)
def jaccard_similarity(text1: str, text2: str) -> float:
    if not text1 or not text2:
        return 0.0

    set1 = set(text1.upper().split())
    set2 = set(text2.upper().split())

    if len(set1) == 0 or len(set2) == 0:
        return 0.0

    intersection = len(set1 & set2)
    union = len(set1 | set2)

    return float(intersection / union) if union > 0 else 0.0

print("✅ Jaccard UDF created.")

# ---------------------------------------------------------
# Levenshtein Distance UDF (from snowpark_features_notebook3.py)
# ---------------------------------------------------------
@udf(
    name="levenshtein_distance",
    return_type=IntegerType(),
    input_types=[StringType(), StringType()],
    is_permanent=True,
    stage_location="@RETAIL_INTELLIGENCE_DB.RAW.RETAIL_STAGE",
    replace=True
)
def levenshtein_distance(s1: str, s2: str) -> int:
    if not s1:
        return len(s2) if s2 else 0
    if not s2:
        return len(s1)
    if s1 == s2:
        return 0

    m, n = len(s1), len(s2)
    d = [[0] * (n + 1) for _ in range(m + 1)]

    for i in range(m + 1):
        d[i][0] = i
    for j in range(n + 1):
        d[0][j] = j

    for j in range(1, n + 1):
        for i in range(1, m + 1):
            cost = 0 if s1[i-1] == s2[j-1] else 1
            d[i][j] = min(
                d[i-1][j] + 1,
                d[i][j-1] + 1,
                d[i-1][j-1] + cost
            )

    return d[m][n]

print("✅ Levenshtein UDF created.")

# ---------------------------------------------------------
# create_product_features() (from snow_features_notebook4.py)
# ---------------------------------------------------------
def create_product_features(session):

    print("Starting feature generation...")

    abt_df = session.table("RAW_STAGING.STG_ABT_PRODUCTS")
    buy_df = session.table("RAW_STAGING.STG_BUY_PRODUCTS")

    # Cross join all products
    pairs_df = (
        abt_df.select(
            col("PRODUCT_ID").alias("ABT_ID"),
            col("PRODUCT_NAME").alias("ABT_NAME"),
            col("DESCRIPTION").alias("ABT_DESC"),
            col("PRICE_NUMERIC").alias("ABT_PRICE"),
            col("NAME_TOKENS").alias("ABT_TOKENS")
        )
        .cross_join(
            buy_df.select(
                col("PRODUCT_ID").alias("BUY_ID"),
                col("PRODUCT_NAME").alias("BUY_NAME"),
                col("DESCRIPTION").alias("BUY_DESC"),
                col("MANUFACTURER").alias("BUY_MANUFACTURER"),
                col("PRICE_NUMERIC").alias("BUY_PRICE"),
                col("NAME_TOKENS").alias("BUY_TOKENS")
            )
        )
    )

    # ---------------------------------------------------------
    # Feature Engineering
    # ---------------------------------------------------------
    features_df = (
        pairs_df
        .with_column("NAME_JACCARD", jaccard_similarity(col("ABT_NAME"), col("BUY_NAME")))
        .with_column("DESC_JACCARD", jaccard_similarity(col("ABT_DESC"), col("BUY_DESC")))
        .with_column("NAME_LEVENSHTEIN", levenshtein_distance(col("ABT_NAME"), col("BUY_NAME")))
        .with_column("TOKEN_OVERLAP", array_size(array_intersection(col("ABT_TOKENS"), col("BUY_TOKENS"))))
        .with_column("PRICE_DIFF_ABS", sf_abs(col("ABT_PRICE") - col("BUY_PRICE")))
        .with_column(
            "PRICE_DIFF_PCT",
            (sf_abs(col("ABT_PRICE") - col("BUY_PRICE")) /
             ((col("ABT_PRICE") + col("BUY_PRICE")) / 2) * 100)
        )
    )

    # ---------------------------------------------------------
    # Candidate Filtering
    # ---------------------------------------------------------
    candidates_df = features_df.filter(
        (col("NAME_JACCARD") > 0.3) |
        (col("TOKEN_OVERLAP") >= 2) |
        (col("PRICE_DIFF_PCT") < 20)
    )

    # ---------------------------------------------------------
    # Save output
    # ---------------------------------------------------------
    candidates_df.write.mode("overwrite").save_as_table(
        "ANALYTICS.PRODUCT_PAIR_FEATURES"
    )

    print("✅ Feature table created successfully!")
    print(f"Total rows: {candidates_df.count()}")

    return candidates_df

# ---------------------------------------------------------
# Session + Execution (from snow_features_notebook5.py)
# ---------------------------------------------------------
from snowflake.snowpark import Session
session = Session.builder.getOrCreate()

print("Session created:", session)

features = create_product_features(session)
features.limit(10).show()
