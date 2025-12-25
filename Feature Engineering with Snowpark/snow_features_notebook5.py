from snowflake.snowpark import Session
session = Session.builder.getOrCreate()

print("Session created:", session)


features = create_product_features(session)
features.limit(10).show()
