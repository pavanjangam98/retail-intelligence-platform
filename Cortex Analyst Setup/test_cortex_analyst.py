import snowflake.snowpark as snowpark
from snowflake.snowpark.context import get_active_session
import json

def main(session: snowpark.Session) -> str:
    """Main function for Snowflake Python Worksheet"""
    
    # Configure context
    session.sql("USE WAREHOUSE RETAIL_WH").collect()
    session.sql("USE DATABASE RETAIL_INTELLIGENCE_DB").collect()
    session.sql("USE SCHEMA ANALYTICS").collect()
    
    # Load semantic model
    semantic_model_path = "@RETAIL_INTELLIGENCE_DB.ANALYTICS.CORTEX_ANALYST_STAGE/retail_semantic_model.yaml"
    
    # Create file format if needed
    session.sql("""
        CREATE FILE FORMAT IF NOT EXISTS yaml_format
        TYPE = 'CSV'
        FIELD_DELIMITER = NONE
        RECORD_DELIMITER = NONE
    """).collect()
    
    # Read semantic model
    yaml_df = session.sql(f"""
        SELECT $1 AS content
        FROM {semantic_model_path}
        (FILE_FORMAT => yaml_format)
    """).collect()
    
    semantic_model = '\n'.join([row['CONTENT'] for row in yaml_df])
    
    # ========================================================================
    # YOUR QUESTION HERE - CUSTOMIZE THIS!
    # ========================================================================
    
    question = "What are the top 5 products with the biggest price differences where ABT is more expensive?"
    
    # ========================================================================
    
    print(f"Question: {question}\n")
    print("="*70)
    
    # Create prompt
    prompt = f"""You are a SQL expert. Given this semantic model:

{semantic_model[:4000]}

Generate ONLY executable Snowflake SQL (no explanations) to answer: "{question}"

Use proper table names and JOINs from the model above.

SQL:"""
    
    # Generate SQL
    result = session.sql(f"""
        SELECT SNOWFLAKE.CORTEX.COMPLETE(
            'llama3.1-70b',
            $${prompt}$$
        ) AS sql
    """).collect()
    
    generated_sql = result[0]['SQL'].strip()
    
    # Clean markdown if present
    if '```sql' in generated_sql:
        generated_sql = generated_sql.split('```sql')[1].split('```')[0].strip()
    elif '```' in generated_sql:
        generated_sql = generated_sql.split('```')[1].split('```')[0].strip()
    
    print(f"Generated SQL:\n{generated_sql}\n")
    print("="*70)
    print()
    
    # Execute
    try:
        df = session.sql(generated_sql).to_pandas()
        print(f"✅ Results ({len(df)} rows):\n")
        print(df.to_string())
        return "Success"
    except Exception as e:
        print(f"❌ Error executing SQL: {e}")
        print("\nYou may need to manually adjust the SQL above")
        return f"Error: {e}"

# Call main function
main(get_active_session())