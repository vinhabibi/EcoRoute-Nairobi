"""EcoRoute Nairobi - Streamlit explorer.

Run:  streamlit run streamlit_app.py
Expects data/nodes.csv and data/edges.csv next to this file (or upload them in the sidebar).
Mirrors the Oracle emission model in ecoroute_backend.sql so numbers are comparable.
"""
from pathlib import Path
import random

import altair as alt
import networkx as nx
import pandas as pd
import pydeck as pdk
import streamlit as st

st.set_page_config(page_title="EcoRoute Nairobi", layout="wide")

# Same placeholder vehicles as the SQL script (replace with sourced factors).
VEHICLES = pd.DataFrame(
    [("Delivery van", 1000, 0.25), ("Light truck", 3000, 0.45), ("Medium truck", 8000, 0.75)],
    columns=["vehicle_type", "capacity_kg", "base_kg_co2_per_km"],
)
CLASS_COLOURS = {
    "motorway": [140, 20, 20], "trunk": [215, 48, 39], "primary": [244, 109, 67],
    "secondary": [253, 174, 97], "tertiary": [120, 120, 120],
}
GRADIENT = {  # ASSUMPTION, same as section B of ecoroute_dashboard.sql
    "motorway": 1.8, "trunk": 1.7, "primary": 1.5, "secondary": 1.2,
}


# ------------------------------------------------------------------ data
def read_csv(name: str, upload):
    if upload is not None:
        return pd.read_csv(upload).rename(columns=str.lower)
    for base in (Path(__file__).parent / "data", Path("data"), Path(".")):
        if (base / name).exists():
            return pd.read_csv(base / name).rename(columns=str.lower)  # Oracle exports are UPPERCASE
    return None


with st.sidebar:
    st.header("Data")
    up_n = st.file_uploader("nodes.csv", type="csv")
    up_e = st.file_uploader("edges.csv", type="csv")
nodes, edges = read_csv("nodes.csv", up_n), read_csv("edges.csv", up_e)
if nodes is None or edges is None:
    st.info("Put nodes.csv and edges.csv in a data/ folder, or upload them in the sidebar.")
    st.stop()

with st.sidebar:
    st.header("Model")
    cong_mode = st.radio(
        "Congestion",
        ["As in CSV (free flow)", "Assumed gradient by road class"],
        help="edges.csv has congestion_factor = 1.0 everywhere, so ECO and FASTEST rarely differ.",
    )
    n_jobs = st.slider("Simulated jobs", 20, 500, 100, step=20)
    seed = st.number_input("Random seed", value=42, step=1)


def apply_congestion(df: pd.DataFrame, mode: str) -> pd.DataFrame:
    df = df.copy()
    if mode.startswith("Assumed"):
        jitter = 0.9 + (df["edge_id"] % 21) / 100  # deterministic; not Oracle's ORA_HASH
        base = df["road_class"].str.replace("_link", "", regex=False).map(GRADIENT).fillna(1.0)
        df["congestion_factor"] = (base * jitter).clip(lower=1).round(2)
    return df


edges = apply_congestion(edges, cong_mode)
edges["time_s"] = edges["length_m"] / (edges["speed_kph"] / 3.6) * edges["congestion_factor"]
# CO2 per edge = km * base * load_factor * congestion_factor_term. Only the last two parts
# depend on the edge, so the ECO route does not depend on vehicle or payload.
edges["eco_km"] = edges["length_m"] / 1000 * (1 + 0.25 * (edges["congestion_factor"].clip(lower=1) - 1))


@st.cache_resource
def build_graphs(e: pd.DataFrame):
    """Collapse parallel edges to the best one per mode, like the Dijkstra in PL/SQL."""
    def make(weight_col):
        g = nx.DiGraph()
        for r in e.sort_values(weight_col).drop_duplicates(["src_node", "dst_node"]).itertuples():
            g.add_edge(r.src_node, r.dst_node, w=getattr(r, weight_col),
                       L=r.length_m, T=r.time_s, F=r.eco_km)
        return g
    return make("time_s"), make("eco_km")


G_fast, G_eco = build_graphs(edges)
coords = nodes.set_index("node_id")[["lon", "lat"]]


def totals(g, path):
    es = [g[a][b] for a, b in zip(path, path[1:])]
    return sum(x["L"] for x in es) / 1000, sum(x["T"] for x in es) / 60, sum(x["F"] for x in es)


@st.cache_data
def simulate(_g_fast, _g_eco, n, seed, key):
    rng = random.Random(seed)
    main = max(nx.strongly_connected_components(_g_fast), key=len)  # ~40 nodes are unroutable
    pool = sorted(main)
    rows = []
    for job_id in range(1, n + 1):
        o, d = rng.sample(pool, 2)
        v = VEHICLES.iloc[rng.randrange(len(VEHICLES))]
        payload = round(v.capacity_kg * rng.uniform(0.2, 1.0))
        load = min(payload / v.capacity_kg, 1)
        pf = nx.bidirectional_dijkstra(_g_fast, o, d, "w")[1]  # much faster than plain Dijkstra on 47k nodes
        pe = nx.bidirectional_dijkstra(_g_eco, o, d, "w")[1]
        f_km, f_min, f_F = totals(_g_fast, pf)
        e_km, e_min, e_F = totals(_g_eco, pe)
        scale = v.base_kg_co2_per_km * (1 + 0.5 * load)
        rows.append(dict(job_id=job_id, vehicle_type=v.vehicle_type, payload_kg=payload,
                         load_pct=round(100 * load), origin=o, dest=d,
                         fastest_km=f_km, eco_km=e_km, fastest_min=f_min, eco_min=e_min,
                         fastest_co2=f_F * scale, eco_co2=e_F * scale,
                         path_fast=pf, path_eco=pe))
    df = pd.DataFrame(rows)
    df["co2_saved_kg"] = df.fastest_co2 - df.eco_co2
    df["co2_saved_pct"] = 100 * df.co2_saved_kg / df.fastest_co2
    df["extra_min"] = df.eco_min - df.fastest_min
    df["load_band"] = pd.cut(df.load_pct, [0, 33, 66, 100], labels=["Light", "Medium", "Heavy"])
    return df


jobs = simulate(G_fast, G_eco, n_jobs, int(seed), (cong_mode, len(edges)))
with st.sidebar:
    vsel = st.multiselect("Vehicle filter", VEHICLES.vehicle_type.tolist(),
                          default=VEHICLES.vehicle_type.tolist())
view = jobs[jobs.vehicle_type.isin(vsel)]

st.title("EcoRoute Nairobi - fastest vs eco routes")
tab_dash, tab_route, tab_net = st.tabs(["CO2 dashboard", "Route explorer", "Road network"])

# ------------------------------------------------------------------ dashboard
with tab_dash:
    if view.empty:
        st.warning("No jobs match the filter.")
    else:
        c = st.columns(4)
        c[0].metric("Jobs", len(view))
        c[1].metric("CO2 saved", f"{view.co2_saved_kg.sum():,.1f} kg")
        c[2].metric("Reduction vs fastest", f"{100 * view.co2_saved_kg.sum() / view.fastest_co2.sum():.1f} %")
        c[3].metric("Avg extra time", f"{view.extra_min.mean():.1f} min")
        st.caption(f"{(view.co2_saved_kg > 1e-9).sum()} of {len(view)} jobs get a different (greener) route.")

        a, b = st.columns(2)
        by_v = view.groupby("vehicle_type", as_index=False).co2_saved_kg.sum()
        a.subheader("CO2 saved by vehicle type")
        a.altair_chart(alt.Chart(by_v).mark_bar().encode(
            x=alt.X("vehicle_type", title=None), y=alt.Y("co2_saved_kg", title="kg CO2 saved")),
            width="stretch")
        by_l = view.groupby("load_band", as_index=False, observed=True).co2_saved_pct.mean()
        b.subheader("Average % saved by load band")
        b.altair_chart(alt.Chart(by_l).mark_bar().encode(
            x=alt.X("load_band", sort=["Light", "Medium", "Heavy"], title=None),
            y=alt.Y("co2_saved_pct", title="% saved")), width="stretch")

        a, b = st.columns(2)
        a.subheader("Time cost vs CO2 benefit")
        a.altair_chart(alt.Chart(view).mark_circle(size=60, opacity=0.7).encode(
            x=alt.X("extra_min", title="Extra minutes vs fastest"),
            y=alt.Y("co2_saved_kg", title="kg CO2 saved"), color="vehicle_type",
            tooltip=["job_id", "vehicle_type", "co2_saved_kg", "co2_saved_pct", "extra_min"]),
            width="stretch")
        b.subheader("Distribution of % saved")
        b.altair_chart(alt.Chart(view).mark_bar().encode(
            x=alt.X("co2_saved_pct", bin=alt.Bin(maxbins=20), title="% CO2 saved"),
            y=alt.Y("count()", title="jobs")), width="stretch")

        st.subheader("Top jobs by CO2 saved")
        st.dataframe(view.sort_values("co2_saved_kg", ascending=False).head(15)[
            ["job_id", "vehicle_type", "payload_kg", "fastest_km", "eco_km", "fastest_min",
             "eco_min", "co2_saved_kg", "co2_saved_pct", "extra_min"]].round(2),
            hide_index=True, width="stretch")

# ------------------------------------------------------------------ route explorer
def path_df(path):
    return [[float(coords.at[n, "lon"]), float(coords.at[n, "lat"])] for n in path]


with tab_route:
    if view.empty:
        st.warning("No jobs match the filter.")
    else:
        pick = st.selectbox("Job", view.sort_values("co2_saved_kg", ascending=False).job_id,
                            format_func=lambda j: f"Job {j} - saves {jobs.set_index('job_id').at[j, 'co2_saved_kg']:.2f} kg")
        j = jobs.set_index("job_id").loc[pick]
        layers = [
            pdk.Layer("PathLayer", [dict(path=path_df(j.path_fast), name="FASTEST")],
                      get_path="path", get_color=[215, 48, 39], width_min_pixels=5),
            pdk.Layer("PathLayer", [dict(path=path_df(j.path_eco), name="ECO")],
                      get_path="path", get_color=[26, 152, 80], width_min_pixels=5),
        ]
        mid = path_df(j.path_fast)[len(j.path_fast) // 2]
        st.pydeck_chart(pdk.Deck(layers=layers, height=520,
                                 initial_view_state=pdk.ViewState(longitude=mid[0], latitude=mid[1], zoom=12.5)))
        st.caption("Red = fastest, green = eco (drawn on top where they overlap).")
        st.table(pd.DataFrame({
            "Fastest": [j.fastest_km, j.fastest_min, j.fastest_co2],
            "Eco": [j.eco_km, j.eco_min, j.eco_co2],
        }, index=["Distance (km)", "Time (min)", "CO2 (kg)"]).round(2))

# ------------------------------------------------------------------ network
with tab_net:
    minor = ["residential", "unclassified", "living_street"]
    show_minor = st.checkbox("Include minor roads (residential, unclassified)", value=False,
                             help="Drawing all ~113k segments can make the map slow.")
    e = edges if show_minor else edges[~edges.road_class.isin(minor)]
    e = e.join(coords.add_prefix("s_"), on="src_node").join(coords.add_prefix("d_"), on="dst_node")
    e["colour"] = e.road_class.str.replace("_link", "", regex=False).map(CLASS_COLOURS).apply(
        lambda c: c if isinstance(c, list) else [120, 120, 120])
    st.pydeck_chart(pdk.Deck(
        layers=[pdk.Layer("LineLayer", e, get_source_position="[s_lon, s_lat]",
                          get_target_position="[d_lon, d_lat]", get_color="colour", width_min_pixels=2)],
        initial_view_state=pdk.ViewState(longitude=float(nodes.lon.mean()), latitude=float(nodes.lat.mean()), zoom=11.5),
        height=560))
    st.caption(f"{len(nodes):,} nodes, {len(edges):,} edges ({len(e):,} drawn). Darker red = bigger roads.")
    rc = edges.groupby("road_class", as_index=False).agg(edges=("edge_id", "count"), km=("length_m", lambda s: s.sum() / 1000))
    st.dataframe(rc.round(1), hide_index=True)
