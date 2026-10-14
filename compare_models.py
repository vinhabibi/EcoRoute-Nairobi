import osmnx as ox
import networkx as nx
from ecoroute_emissions import add_eco_weights, run_self_tests
from routing_engine import compare_routes

# --- 1. Sanity: Member 4's self-tests pass? ---
run_self_tests()

# --- 2. Load graph and apply Member 4's weights ---
G = ox.load_graphml("data/nairobi.graphml")   # adjust path if yours is elsewhere
add_eco_weights(G, vehicle="light_van", payload_kg=750, period="PEAK")

# Same OD pair as check_speeds.py: Mombasa Rd -> Thika Rd
orig_lat, orig_lon = -1.3192, 36.8500
dest_lat, dest_lon = -1.219,  36.887

orig = ox.distance.nearest_nodes(G, orig_lon, orig_lat)
dest = ox.distance.nearest_nodes(G, dest_lon, dest_lat)

# --- 3. Member 4's eco route CO2 ---
route = nx.shortest_path(G, orig, dest, weight="co2e_kg")
co2_m4 = 0.0
for u, v in zip(route[:-1], route[1:]):
    edge = G[u][v]
    # pick the min-co2 parallel edge in case of MultiDiGraph
    co2_m4 += min(d["co2e_kg"] for d in edge.values())
print(f"Member 4 eco CO2: {co2_m4:.3f} kg")

# --- 4. Your engine's eco CO2, same coordinates, hour 8 (peak) ---
r = compare_routes((orig_lat, orig_lon), (dest_lat, dest_lon), "van", 0.8, 8)
co2_you = r["eco"]["co2_kg"]
print(f"Your engine eco CO2: {co2_you:.3f} kg")

diff_pct = 100 * abs(co2_m4 - co2_you) / co2_you
print(f"Difference: {diff_pct:.1f}%")