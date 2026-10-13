import networkx as nx
import osmnx as ox
from graph_builder import build_graph
from emissions import edge_fuel_l, EF_KG_PER_L, VEHICLES

CONGESTION = {
    "peak":    {"motorway": .6, "trunk": .45, "primary": .4, "secondary": .45, "default": .6},
    "offpeak": {"motorway": .9, "trunk": .8, "primary": .75, "secondary": .8, "default": .9},
}
PEAK_HOURS = {7, 8, 9, 16, 17, 18, 19}

_G = None
def get_graph():
    global _G
    if _G is None:
        _G = build_graph()
    return _G

def _hwy(d):
    h = d.get("highway", "default")
    return h[0] if isinstance(h, list) else h

def annotate(G, vehicle, load_t, hour):
    prof = CONGESTION["peak" if hour in PEAK_HOURS else "offpeak"]
    fuel_type = VEHICLES[vehicle]["fuel"]
    for u, v, k, d in G.edges(keys=True, data=True):
        eff = float(d["speed_kph"]) * prof.get(_hwy(d), prof["default"])
        length = float(d["length"])
        d["time_s"] = length / (eff / 3.6)
        d["fuel_l"] = edge_fuel_l(length, eff, vehicle, load_t)
        d["co2_kg"] = d["fuel_l"] * EF_KG_PER_L[fuel_type]
    return G

def _totals(G, path, weight):
    out = dict(distance_km=0.0, time_min=0.0, fuel_l=0.0, co2_kg=0.0)
    for u, v in zip(path[:-1], path[1:]):
        d = min(G[u][v].values(), key=lambda e: e[weight])
        out["distance_km"] += d["length"] / 1000
        out["time_min"] += d["time_s"] / 60
        out["fuel_l"] += d["fuel_l"]
        out["co2_kg"] += d["co2_kg"]
    return {k: round(val, 2) for k, val in out.items()}

def compare_routes(origin, dest, vehicle="van", load_t=0.5, hour=8):
    G = annotate(get_graph(), vehicle, load_t, hour)
    o = ox.distance.nearest_nodes(G, origin[1], origin[0])  # X = lon, Y = lat
    t = ox.distance.nearest_nodes(G, dest[1], dest[0])
    modes = {"shortest": "length", "fastest": "time_s", "eco": "co2_kg"}
    res = {}
    for name, w in modes.items():
        path = nx.shortest_path(G, o, t, weight=w)
        res[name] = {"coords": [(G.nodes[n]["y"], G.nodes[n]["x"]) for n in path],
                     **_totals(G, path, w)}
    def pct(base, new):
        return round(100 * (base - new) / base, 1) if base else 0.0
    res["savings"] = {
        "co2_vs_fastest_pct": pct(res["fastest"]["co2_kg"], res["eco"]["co2_kg"]),
        "co2_vs_shortest_pct": pct(res["shortest"]["co2_kg"], res["eco"]["co2_kg"]),
    }
    return res