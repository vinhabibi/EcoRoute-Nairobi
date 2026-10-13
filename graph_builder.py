import os
import osmnx as ox

ox.settings.use_cache = True
CBD = (-1.2864, 36.8172)
GRAPH_PATH = "data/nairobi.graphml"

HWY_SPEEDS = {"motorway": 80, "trunk": 70, "primary": 50, "secondary": 40,
              "tertiary": 35, "residential": 25, "unclassified": 30}

def build_graph(path=GRAPH_PATH, dist=8000):
    if os.path.exists(path):
        return ox.load_graphml(path)
    G = ox.graph_from_point(CBD, dist=dist, network_type="drive")
    G = ox.routing.add_edge_speeds(G, hwy_speeds=HWY_SPEEDS, fallback=30)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ox.save_graphml(G, path)
    return G