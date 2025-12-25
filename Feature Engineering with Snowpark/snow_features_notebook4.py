def create_product_features(session):

    print("Starting feature generation...")

    abt_df = session.table("RAW_STAGING.STG_ABT_PRODUCTS")
    buy_df = session.table("RAW_STAGING.STG_BUY_PRODUCTS")

    # Cross join all products (can optimize later)
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
