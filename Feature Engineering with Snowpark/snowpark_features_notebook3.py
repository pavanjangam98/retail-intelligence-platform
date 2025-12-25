# Levenshtein UDF created

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
