"""
Evaluates SHORTEST vs ECO routing on the real nairobi.graphml using the EcoRoute emission model.
Prints edge-level (exact within the model) CO2e savings for all pairs of the 10 sample locations,
for peak and off-peak, so the deck quotes numbers that real code produced.

Usage (Windows):  pip install networkx   then   python evaluate_savings.py nairobi.graphml
Needs ecoroute_emissions.py in the same folder.
"""
import sys, itertools
import networkx as nx
from ecoroute_emissions import add_eco_weights

GRAPHML = sys.argv[1] if len(sys.argv) > 1 else "nairobi.graphml"
LOCS = {"CBD": (-1.2864, 36.8172), "Westlands": (-1.2673, 36.8110), "Industrial Area": (-1.3070, 36.8530),
        "Eastleigh": (-1.2756, 36.8506), "Kilimani": (-1.2903, 36.7845), "Karen": (-1.3197, 36.7073),
        "Roysambu": (-1.2185, 36.8870), "Embakasi": (-1.3200, 36.9000), "Donholm": (-1.2950, 36.8930),
        "Gigiri": (-1.2330, 36.8050)}

G = nx.read_graphml(GRAPHML)
for _, _, _, d in G.edges(keys=True, data=True):
    d["len_f"] = float(d["length"])
nodes = list(G.nodes)
xy = {n: (float(G.nodes[n]["y"]), float(G.nodes[n]["x"])) for n in nodes}
nearest = {k: min(nodes, key=lambda n: (xy[n][0] - p[0]) ** 2 + (xy[n][1] - p[1]) ** 2) for k, p in LOCS.items()}
cost = lambda p, a: sum(min(x[a] for x in G[u][v].values()) for u, v in zip(p, p[1:]))

for vehicle, payload in (("light_van", 750), ("rigid_truck_7_5t", 5500)):
    for period in ("PEAK", "OFFPEAK"):
        add_eco_weights(G, vehicle, payload, period)
        sav, differ = [], 0
        for a, b in itertools.combinations(LOCS, 2):
            ps = nx.shortest_path(G, nearest[a], nearest[b], weight="len_f")
            pe = nx.shortest_path(G, nearest[a], nearest[b], weight="co2e_kg")
            cs, ce = cost(ps, "co2e_kg"), cost(pe, "co2e_kg")
            differ += ps != pe
            sav.append(100 * (cs - ce) / cs)
        print(f"{vehicle:17s} {period:8s} pairs={len(sav)} eco differs on {differ} | "
              f"savings min {min(sav):.1f}%  avg {sum(sav)/len(sav):.1f}%  max {max(sav):.1f}%")
