import networkx as nx
import osmnx as ox
from collections import defaultdict
from routing_engine import get_graph, annotate, _hwy

TRIPS = {
    "CBD -> Westlands": ((-1.2864, 36.8172), (-1.2676, 36.8108)),
    "Mombasa Rd -> Thika Rd": ((-1.3192, 36.8500), (-1.219, 36.887)),
}

G = annotate(get_graph(), "van", 0.8, 8)
for label, (a, b) in TRIPS.items():
    o = ox.distance.nearest_nodes(G, a[1], a[0])
    t = ox.distance.nearest_nodes(G, b[1], b[0])
    path = nx.shortest_path(G, o, t, weight="time_s")
    km = defaultdict(float)
    for u, v in zip(path[:-1], path[1:]):
        d = min(G[u][v].values(), key=lambda e: e["time_s"])
        km[_hwy(d)] += d["length"] / 1000
    total = sum(km.values())
    print(label, f"({total:.1f} km)")
    for cls, k in sorted(km.items(), key=lambda x: -x[1]):
        print(f"  {cls:14} {k:5.1f} km  {100*k/total:3.0f}%")
    print()