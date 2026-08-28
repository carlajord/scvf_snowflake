"""
Well Integrity Dashboard — Streamlit in Snowflake
Reads from WELL_INTEGRITY.GOLD.WELLS_GOLD and WELL_INTEGRITY.SILVER.SCVF_SILVER.
Deploy: Snowsight > Streamlit > Create Streamlit App > paste this file as app.py.
Set the app's database/schema to WELL_INTEGRITY / GOLD (or any schema — this
script fully-qualifies its table references, so location doesn't matter).
Add "pydeck" under Packages in the app's environment settings before running.
"""

import json
import requests
import streamlit as st
import pandas as pd
import pydeck as pdk
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Well Integrity Dashboard", layout="wide")

session = get_active_session()

SEMANTIC_VIEW = "WELL_INTEGRITY.GOLD.WELL_INTEGRITY_SV"

RISK_COLORS = {
    "High":   [220, 75, 74],    # c-red 400
    "Medium": [239, 159, 39],   # c-amber 400
    "Low":    [99, 153, 34],    # c-green 400
}


@st.cache_data(ttl=600)
def load_wells() -> pd.DataFrame:
    return session.table("WELL_INTEGRITY.GOLD.WELLS_GOLD").to_pandas()


@st.cache_data(ttl=600)
def load_scvf_trend() -> pd.DataFrame:
    return session.sql("""
        SELECT
            DATE_TRUNC('month', test_date) AS test_month,
            severity,
            COUNT(*) AS test_count
        FROM WELL_INTEGRITY.SILVER.SCVF_SILVER
        WHERE test_date IS NOT NULL
        GROUP BY 1, 2
        ORDER BY 1
    """).to_pandas()


wells = load_wells()

st.title("Well integrity dashboard")
st.caption("BC Energy Regulator well data — SCVF, casing, and composite risk score")

# ---------------------------------------------------------------------------
# Tabs: Dashboard + Chat
# ---------------------------------------------------------------------------
tab_dashboard, tab_chat = st.tabs(["Dashboard", "Ask a Question"])

# ---------------------------------------------------------------------------
# TAB 1: Dashboard
# ---------------------------------------------------------------------------
with tab_dashboard:
    # Sidebar filters
    st.sidebar.header("Filters")

    operators = sorted(wells["OPERATOR_NAME"].dropna().unique().tolist())
    selected_operators = st.sidebar.multiselect("Operator", operators)

    modes = sorted(wells["WELL_MODE"].dropna().unique().tolist())
    selected_modes = st.sidebar.multiselect("Well status", modes)

    tiers = ["High", "Medium", "Low"]
    selected_tiers = st.sidebar.multiselect("Risk tier", tiers, default=tiers)

    filtered = wells.copy()
    if selected_operators:
        filtered = filtered[filtered["OPERATOR_NAME"].isin(selected_operators)]
    if selected_modes:
        filtered = filtered[filtered["WELL_MODE"].isin(selected_modes)]
    if selected_tiers:
        filtered = filtered[filtered["RISK_TIER"].isin(selected_tiers)]

    # KPI tiles
    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Wells shown", f"{len(filtered):,}")
    col2.metric("High risk", f"{(filtered['RISK_TIER'] == 'High').sum():,}")
    col3.metric("Ever serious SCVF", f"{(filtered['EVER_SERIOUS_SCVF'] == 1).sum():,}")
    col4.metric("Ever H2S present", f"{(filtered['EVER_H2S_PRESENT'] == 1).sum():,}")

    st.divider()

    # Map
    st.subheader("Well locations by risk tier")

    map_df = filtered.dropna(subset=["LATITUDE", "LONGITUDE"]).copy()
    map_df["color"] = map_df["RISK_TIER"].map(RISK_COLORS)
    map_df["color"] = map_df["color"].apply(lambda c: c if isinstance(c, list) else [136, 135, 128])

    if len(map_df) > 0:
        view_state = pdk.ViewState(
            latitude=float(map_df["LATITUDE"].median()),
            longitude=float(map_df["LONGITUDE"].median()),
            zoom=5,
        )
        layer = pdk.Layer(
            "ScatterplotLayer",
            data=map_df,
            get_position="[LONGITUDE, LATITUDE]",
            get_fill_color="color",
            get_radius=800,
            pickable=True,
            opacity=0.7,
        )
        tooltip = {
            "html": "<b>{WELL_NAME}</b><br/>Risk: {RISK_TIER} ({RISK_SCORE})"
                    "<br/>Status: {WELL_MODE}<br/>Operator: {OPERATOR_NAME}",
            "style": {"backgroundColor": "steelblue", "color": "white"},
        }
        st.pydeck_chart(pdk.Deck(
            layers=[layer],
            initial_view_state=view_state,
            tooltip=tooltip,
            map_style=None,
        ))
        st.caption("Red = high risk, amber = medium, green = low. "
                   "Wells missing coordinates are excluded from the map.")
    else:
        st.info("No wells match the current filters.")

    st.divider()

    # SCVF trend chart
    st.subheader("SCVF test volume over time, by severity")

    trend = load_scvf_trend()
    if len(trend) > 0:
        pivot = trend.pivot_table(
            index="TEST_MONTH", columns="SEVERITY", values="TEST_COUNT", fill_value=0
        )
        st.line_chart(pivot)
    else:
        st.info("No SCVF test data available.")

    st.divider()

    # Detail table
    st.subheader("Well detail")
    display_cols = [
        "WA_NUM", "WELL_NAME", "OPERATOR_NAME", "WELL_MODE", "RISK_TIER",
        "RISK_SCORE", "LATEST_SCVF_SEVERITY", "EVER_H2S_PRESENT",
        "OLDEST_CASING_AGE_YEARS",
    ]
    display_cols = [c for c in display_cols if c in filtered.columns]
    st.dataframe(
        filtered[display_cols].sort_values("RISK_SCORE", ascending=False),
        use_container_width=True,
        hide_index=True,
    )

# ---------------------------------------------------------------------------
# TAB 2: Chat with Cortex Analyst
# ---------------------------------------------------------------------------
with tab_chat:
    st.subheader("Ask questions about well integrity data")
    st.caption(
        "Powered by Cortex Analyst. Ask natural language questions about wells, "
        "risk scores, SCVF tests, casing condition, and operators."
    )

    if "messages" not in st.session_state:
        st.session_state.messages = []

    if st.button("Clear chat history"):
        st.session_state.messages = []
        st.rerun()

    def send_analyst_message(prompt: str) -> dict:
        """Send a question to Cortex Analyst and return the response."""
        request_body = {
            "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}]}],
            "semantic_view": SEMANTIC_VIEW,
        }
        conn = session.connection
        host = conn.host
        token = conn.rest.token
        resp = requests.post(
            f"https://{host}/api/v2/cortex/analyst/message",
            json=request_body,
            headers={
                "Authorization": f'Snowflake Token="{token}"',
                "Content-Type": "application/json",
            },
            timeout=30,
        )
        if resp.status_code < 400:
            return resp.json()
        else:
            raise Exception(
                f"Analyst API error (status {resp.status_code}): {resp.text}"
            )

    def display_analyst_content(content: list):
        """Render Cortex Analyst response content blocks."""
        for item in content:
            if item["type"] == "text":
                st.markdown(item["text"])
            elif item["type"] == "sql":
                with st.expander("Generated SQL", expanded=False):
                    st.code(item["statement"], language="sql")
                with st.spinner("Running query..."):
                    df = session.sql(item["statement"]).to_pandas()
                st.dataframe(df, use_container_width=True, hide_index=True)
            elif item["type"] == "suggestions":
                st.markdown("**Suggested follow-up questions:**")
                for suggestion in item["suggestions"]:
                    st.markdown(f"- {suggestion}")

    for msg in st.session_state.messages:
        role = msg["role"]
        with st.chat_message(role):
            if role == "user":
                st.markdown(msg["content"][0]["text"])
            else:
                display_analyst_content(msg["content"])

    if user_input := st.chat_input("Ask a question about well integrity data..."):
        with st.chat_message("user"):
            st.markdown(user_input)

        st.session_state.messages.append(
            {"role": "user", "content": [{"type": "text", "text": user_input}]}
        )

        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                response = send_analyst_message(user_input)
                content = response["message"]["content"]
                display_analyst_content(content)

        st.session_state.messages.append(
            {"role": "assistant", "content": content}
        )
