import streamlit as st
from snowflake.snowpark.context import get_active_session
import pandas as pd
from datetime import datetime

# Page configuration
st.set_page_config(
    page_title="Retail Intelligence Platform",
    page_icon="🛍️",
    layout="wide",
    initial_sidebar_state="expanded"
)

# Custom CSS for better styling
st.markdown("""
<style>
    .main-header {
        font-size: 3rem;
        font-weight: bold;
        color: #1f77b4;
        text-align: center;
        padding: 1rem;
    }
    .metric-card {
        background-color: #f0f2f6;
        padding: 1rem;
        border-radius: 0.5rem;
        text-align: center;
    }
    .stTabs [data-baseweb="tab-list"] {
        gap: 2rem;
    }
</style>
""", unsafe_allow_html=True)

# Get Snowflake session
@st.cache_resource
def get_session():
    return get_active_session()

session = get_session()

# App header
st.markdown('<h1 class="main-header">🛍️ Retail Intelligence Platform</h1>', unsafe_allow_html=True)
st.markdown("---")

# Tabs
tab1, tab2, tab3 = st.tabs(["📊 Dashboard", "🔍 Product Search", "💬 AI Assistant"])

# ============================================================================
# REPORT GENERATOR FUNCTION
# ============================================================================
def generate_markdown_report(session):
    """Generate Markdown report summarizing insights"""

    report_date = datetime.now().strftime("%Y-%m-%d")

    sql = """
    SELECT 
        COUNT(*) AS total_matches,
        ROUND(AVG(semantic_similarity), 3) AS avg_similarity,
        COUNT(DISTINCT abt_id) AS unique_products
    FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
    """

    df = session.sql(sql).to_pandas()

    total_matches = int(df["TOTAL_MATCHES"].iloc[0])
    avg_similarity = float(df["AVG_SIMILARITY"].iloc[0])
    unique_products = int(df["UNIQUE_PRODUCTS"].iloc[0])

    report_md = f"""
# 🛍️ Retail Intelligence Report  
**Generated:** {report_date}

---

## 📊 Summary Statistics
- **Total Matches:** {total_matches:,}
- **Average Similarity:** {avg_similarity:.3f}
- **Unique Products:** {unique_products:,}

---

## 🧠 Insights
You can expand this section with:
- Price distribution insights  
- Category-level analytics  
- Top products  
- Trends and recommendations  

---

*Report generated automatically by the Retail Intelligence Platform.*
"""

    return report_md

# ============================================================================
# TAB 1: DASHBOARD
# ============================================================================
with tab1:
    st.header("Product Match Analytics")

    @st.cache_data(ttl=300)
    def load_summary_stats():
        query = """
        SELECT 
            COUNT(*) as total_matches,
            ROUND(AVG(semantic_similarity), 3) as avg_similarity,
            COUNT(DISTINCT abt_id) as unique_products,
            MIN(semantic_similarity) as min_similarity,
            MAX(semantic_similarity) as max_similarity
        FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
        """
        try:
            return session.sql(query).to_pandas()
        except:
            return pd.DataFrame()

    df_stats = load_summary_stats()

    if not df_stats.empty:
        col1, col2, col3, col4 = st.columns(4)

        col1.metric("Total Matches", f"{df_stats['TOTAL_MATCHES'].iloc[0]:,}")
        col2.metric("Avg Similarity", f"{df_stats['AVG_SIMILARITY'].iloc[0]:.3f}")
        col3.metric("Unique Products", f"{df_stats['UNIQUE_PRODUCTS'].iloc[0]:,}")
        col4.metric("Similarity Range",
                    f"{df_stats['MIN_SIMILARITY'].iloc[0]:.2f} - {df_stats['MAX_SIMILARITY'].iloc[0]:.2f}")

        st.markdown("---")

        col_left, col_right = st.columns(2)

        # Similarity Distribution
        with col_left:
            st.subheader("📈 Similarity Distribution")

            @st.cache_data(ttl=300)
            def load_similarity_distribution():
                query = """
                SELECT 
                    CASE 
                        WHEN semantic_similarity >= 0.9 THEN '0.9 - 1.0'
                        WHEN semantic_similarity >= 0.8 THEN '0.8 - 0.9'
                        WHEN semantic_similarity >= 0.7 THEN '0.7 - 0.8'
                        WHEN semantic_similarity >= 0.6 THEN '0.6 - 0.7'
                        ELSE '< 0.6'
                    END as similarity_range,
                    COUNT(*) as count
                FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
                GROUP BY similarity_range
                ORDER BY similarity_range DESC
                """
                return session.sql(query).to_pandas()

            df_dist = load_similarity_distribution()
            if not df_dist.empty:
                st.bar_chart(df_dist.set_index("SIMILARITY_RANGE")["COUNT"])

        # Price Distribution
        with col_right:
            st.subheader("💰 Price Distribution")

            @st.cache_data(ttl=300)
            def load_price_stats():
                query = """
                SELECT 
                    CASE 
                        WHEN abt_price < 100 THEN '$0-100'
                        WHEN abt_price < 500 THEN '$100-500'
                        WHEN abt_price < 1000 THEN '$500-1000'
                        ELSE '$1000+'
                    END as price_range,
                    COUNT(*) as count
                FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
                WHERE abt_price IS NOT NULL
                GROUP BY price_range
                ORDER BY 
                    CASE 
                        WHEN price_range = '$0-100' THEN 1
                        WHEN price_range = '$100-500' THEN 2
                        WHEN price_range = '$500-1000' THEN 3
                        ELSE 4
                    END
                """
                return session.sql(query).to_pandas()

            df_price = load_price_stats()
            if not df_price.empty:
                st.bar_chart(df_price.set_index("PRICE_RANGE")["COUNT"])

        st.markdown("---")
        st.subheader("🏆 Top Matched Products")

        @st.cache_data(ttl=300)
        def load_top_products():
            query = """
            SELECT 
                abt_id AS "Product ID",
                abt_name AS "Product Name",
                ROUND(abt_price, 2) AS "Price ($)",
                ROUND(semantic_similarity, 3) AS "Similarity",
                buy_name AS "Matched Product"
            FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
            WHERE semantic_similarity >= 0.8
            ORDER BY semantic_similarity DESC
            LIMIT 10
            """
            return session.sql(query).to_pandas()

        df_top = load_top_products()
        if not df_top.empty:
            st.dataframe(df_top, use_container_width=True, hide_index=True)

        st.markdown("---")
        st.subheader("📄 Export Insights")

        # EXPORT REPORT BUTTON
        if st.button("📄 Generate Report"):
            report = generate_markdown_report(session)

            st.download_button(
                label="⬇️ Download Markdown Report",
                data=report,
                file_name=f"retail_intelligence_report_{datetime.now().strftime('%Y%m%d')}.md",
                mime="text/markdown"
            )
            st.success("Report generated successfully!")

# ============================================================================
# TAB 2: PRODUCT SEARCH
# ============================================================================
with tab2:
    st.header("Search Products")
    st.markdown("Enter a product name to find matches in the catalog")

    search_term = st.text_input("Enter product name:", placeholder="e.g., camera, laptop, phone...")

    col1, col2, col3 = st.columns(3)
    min_similarity = col1.slider("Minimum Similarity", 0.0, 1.0, 0.5, 0.05)
    price_range = col2.selectbox("Price Range",
                                 ["All", "$0-100", "$100-500", "$500-1000", "$1000+"])
    max_results = col3.selectbox("Max Results", [10, 25, 50, 100], index=1)

    if search_term:
        with st.spinner("Searching..."):

            price_filter = ""
            if price_range == "$0-100":
                price_filter = "AND abt_price < 100"
            elif price_range == "$100-500":
                price_filter = "AND abt_price BETWEEN 100 AND 500"
            elif price_range == "$500-1000":
                price_filter = "AND abt_price BETWEEN 500 AND 1000"
            elif price_range == "$1000+":
                price_filter = "AND abt_price >= 1000"

            query = f"""
            SELECT 
                abt_id AS "Product ID",
                abt_name AS "Product Name",
                LEFT(abt_description, 80) || '...' AS "Description",
                ROUND(abt_price, 2) AS "Price ($)",
                buy_name AS "Matched Product",
                ROUND(semantic_similarity, 3) AS "Similarity"
            FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
            WHERE LOWER(abt_name) LIKE LOWER('%{search_term}%')
                AND semantic_similarity >= {min_similarity}
                {price_filter}
            ORDER BY semantic_similarity DESC
            LIMIT {max_results}
            """

            try:
                df_results = session.sql(query).to_pandas()

                if not df_results.empty:
                    st.success(f"Found {len(df_results)} matching products")
                    st.dataframe(df_results, use_container_width=True, hide_index=True)

                    csv = df_results.to_csv(index=False)
                    st.download_button(
                        label="📥 Download CSV",
                        data=csv,
                        file_name=f"product_search_{search_term}_{datetime.now().strftime('%Y%m%d')}.csv",
                        mime="text/csv"
                    )
                else:
                    st.warning("No products found")
            except Exception as e:
                st.error(str(e))

    else:
        st.info("Enter a product name to search.")

# ============================================================================
# TAB 3: AI ASSISTANT
# ============================================================================
with tab3:
    st.header("🤖 AI-Powered Product Assistant")

    if "messages" not in st.session_state:
        st.session_state.messages = []

    with st.expander("💡 Sample Questions", expanded=True):
        st.markdown("""
        - Show me the top 5 products with highest similarity scores  
        - Find all cameras  
        - What products are priced under $500?  
        - Avg price of all products  
        - Count of products above 0.9 similarity  
        """)

    for message in st.session_state.messages:
        with st.chat_message(message["role"]):
            st.markdown(message["content"])
            if "dataframe" in message and message["dataframe"] is not None:
                st.dataframe(message["dataframe"], use_container_width=True, hide_index=True)

    if prompt := st.chat_input("Ask me anything about the catalog..."):
        st.session_state.messages.append({"role": "user", "content": prompt})

        with st.chat_message("user"):
            st.markdown(prompt)

        with st.chat_message("assistant"):
            with st.spinner("Analyzing..."):
                try:
                    response_text = ""
                    query = None
                    p = prompt.lower()

                    # Query logic here (same as your code)...

                    # Default output
                    if not query:
                        query = """
                        SELECT 
                            abt_name AS "Product",
                            ROUND(abt_price, 2) AS "Price ($)",
                            buy_name AS "Match",
                            ROUND(semantic_similarity, 3) AS "Similarity"
                        FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
                        ORDER BY semantic_similarity DESC
                        LIMIT 10
                        """
                        response_text = "Here are some top products:"

                    df_result = session.sql(query).to_pandas()

                    if not df_result.empty:
                        st.markdown(response_text)
                        st.dataframe(df_result, use_container_width=True, hide_index=True)

                        st.session_state.messages.append({
                            "role": "assistant",
                            "content": response_text,
                            "dataframe": df_result
                        })
                    else:
                        msg = "No results found."
                        st.info(msg)
                        st.session_state.messages.append({"role": "assistant", "content": msg, "dataframe": None})

                except Exception as e:
                    msg = f"Error: {str(e)}"
                    st.error(msg)
                    st.session_state.messages.append({"role": "assistant", "content": msg, "dataframe": None})

    if st.button("🗑️ Clear Chat"):
        st.session_state.messages = []
        st.rerun()

# ============================================================================
# SIDEBAR
# ============================================================================
with st.sidebar:
    st.header("ℹ️ About")
    st.markdown("""
This platform provides:
- **Semantic Search**
- **Live Analytics**
- **AI Assistant**
- **Interactive Filtering**
""")

    st.markdown("---")
    st.header("📊 Quick Stats")

    try:
        quick_stats = session.sql("""
            SELECT 
                COUNT(*) AS total,
                COUNT(DISTINCT abt_id) AS products,
                ROUND(AVG(semantic_similarity), 3) AS avg_sim
            FROM RETAIL_INTELLIGENCE_DB.ANALYTICS.PRODUCT_MATCHES_AI
        """).to_pandas()

        st.metric("Total Records", f"{quick_stats['TOTAL'].iloc[0]:,}")
        st.metric("Unique Products", f"{quick_stats['PRODUCTS'].iloc[0]:,}")
        st.metric("Avg Similarity", f"{quick_stats['AVG_SIM'].iloc[0]:.3f}")

    except:
        st.info("Stats unavailable")

    st.markdown("---")
    st.markdown("**Last Updated:** " + datetime.now().strftime("%Y-%m-%d %H:%M:%S"))

    if st.button("🔄 Refresh Data"):
        st.cache_data.clear()
        st.rerun()

    st.markdown("---")
    st.caption("Built with Snowflake + Streamlit")
