"""
Export a Nairobi road network from OpenStreetMap as two CSV files that match
the EcoRoute tables:

  nodes.csv -> NODES (node_id, lat, lon)
  edges.csv -> EDGES (edge_id, src_node, dst_node, name, road_class,
                      length_m, speed_kph, congestion_factor)

Run once, on a computer with internet access:
  pip install osmnx pandas
  python export_osm_nairobi.py

If the graph is too big or too small, change DIST_M (radius in metres) or
ROAD_FILTER below. Major roads only keeps it to a few thousand edges, which
the PL/SQL routing handles quickly.
"""
import re

import osmnx as ox
import pandas as pd

# Centre between the CBD, Westlands and the Industrial Area
CENTER = (-1.2900, 36.8300)   # (lat, lon)
DIST_M = 5500                 # radius in metres
ROAD_FILTER = '["highway"~"motorway|trunk|primary|secondary|tertiary"]'

# Default speeds (km/h) used when OpenStreetMap has no usable maxspeed tag.
# These are assumptions for urban Nairobi; adjust if you have better data.
DEFAULT_SPEED = {
    "motorway": 80, "trunk": 70, "primary": 50,
    "secondary": 40, "tertiary": 35,
}


def first(value):
    """OSM attributes can be lists after simplification; keep the first item."""
    if isinstance(value, (list, tuple)):
        return value[0] if value else None
    return value


def parse_speed(maxspeed, road_class):
    value = first(maxspeed)
    if value is not None and not (isinstance(value, float) and pd.isna(value)):
        match = re.search(r"\d+(\.\d+)?", str(value))
        if match:
            speed = float(match.group())
            if "mph" in str(value).lower():
                speed *= 1.609
            if speed > 0:
                return round(speed)
    return DEFAULT_SPEED.get(road_class, 30)


def main():
    print("Downloading road network from OpenStreetMap...")
    graph = ox.graph_from_point(CENTER, dist=DIST_M, custom_filter=ROAD_FILTER, simplify=True)
    nodes, edges = ox.graph_to_gdfs(graph)
    print(f"Downloaded {len(nodes)} nodes and {len(edges)} edges")

    nodes_out = pd.DataFrame({
        "node_id": nodes.index.astype("int64"),
        "lat": nodes["y"].round(6).values,
        "lon": nodes["x"].round(6).values,
    })

    edges = edges.reset_index()
    road_class = edges["highway"].apply(first)
    name = edges["name"].apply(first) if "name" in edges.columns else pd.Series([None] * len(edges))
    maxspeed = edges["maxspeed"] if "maxspeed" in edges.columns else pd.Series([None] * len(edges))

    edges_out = pd.DataFrame({
        "edge_id": range(1, len(edges) + 1),
        "src_node": edges["u"].astype("int64"),
        "dst_node": edges["v"].astype("int64"),
        "name": name.fillna("").astype(str).str.slice(0, 200).values,
        "road_class": road_class.fillna("").astype(str).str.slice(0, 30).values,
        "length_m": edges["length"].round(1).values,
        "speed_kph": [parse_speed(m, rc) for m, rc in zip(maxspeed, road_class)],
        "congestion_factor": 1.0,   # placeholder, tune later (1 = free flow)
    })
    edges_out = edges_out[edges_out["src_node"] != edges_out["dst_node"]]
    edges_out["edge_id"] = range(1, len(edges_out) + 1)

    nodes_out.to_csv("nodes.csv", index=False, encoding="utf-8")
    edges_out.to_csv("edges.csv", index=False, encoding="utf-8")
    print(f"Wrote nodes.csv ({len(nodes_out)} rows) and edges.csv ({len(edges_out)} rows)")


if __name__ == "__main__":
    main()
