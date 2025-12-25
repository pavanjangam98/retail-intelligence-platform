# Jaccard UDF created

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
