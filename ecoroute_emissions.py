"""
EcoRoute Nairobi - emission model (Python mirror of the Oracle eco_calc_co2e function).

Hand this file to Member 1. Keep the numbers identical to the ECO_* tables in Oracle;
if you change a factor in APEX, change it here (or load from the DB with load_from_db()).

Usage with the graph:
    import osmnx as ox, networkx as nx
    from ecoroute_emissions import add_eco_weights, run_self_tests
    G = ox.load_graphml("nairobi.graphml")
    add_eco_weights(G, vehicle="light_van", payload_kg=750, period="PEAK")
    route = nx.shortest_path(G, orig, dest, weight="co2e_kg")      # ECO route
    route_short = nx.shortest_path(G, orig, dest, weight="length")  # SHORTEST route
"""
import ast

# ---- Constants: must match Oracle tables (ECO_EMISSION_FACTORS, ECO_VEHICLE_CLASSES, ...) ----
FUEL_KG_CO2E_PER_L = {"DIESEL": 2.68, "PETROL": 2.31}

# name: (fuel, payload_cap_kg, l_per_100km_empty, l_per_100km_full)
VEHICLES = {
    "cargo_motorbike": ("PETROL", 150, 2.5, 3.0),
    "light_van":       ("DIESEL", 1000, 9.0, 12.0),
    "rigid_truck_7_5t": ("DIESEL", 7500, 18.0, 26.0),
    "heavy_truck_20t": ("DIESEL", 20000, 24.0, 38.0),
}

# (min_kph, max_kph, multiplier) - fuel per km is higher at low average speeds
SPEED_CORRECTION = [
    (0, 10, 1.60), (10, 20, 1.35), (20, 30, 1.15),
    (30, 60, 1.00), (60, 80, 1.05), (80, 999, 1.20),
]

# highway class: (peak_cap_kph, offpeak_cap_kph)
ROAD_SPEED_CAPS = {
    "motorway": (60, 80), "trunk": (25, 55), "primary": (20, 40),
    "secondary": (18, 35), "tertiary": (15, 30), "residential": (15, 25),
    "unclassified": (15, 25), "living_street": (10, 15), "default": (15, 25),
}


def speed_multiplier(speed_kph: float) -> float:
    for lo, hi, m in SPEED_CORRECTION:
        if lo <= speed_kph < hi:
            return m
    return 1.0


def calc_co2e(distance_km, payload_kg, vehicle, avg_speed_kph=40.0):
    """kg CO2e for a trip. Same logic as Oracle eco_calc_co2e."""
    fuel, cap, empty, full = VEHICLES[vehicle]
    load = min(max(payload_kg / cap, 0.0), 1.0)
    litres = distance_km * (empty + (full - empty) * load) / 100.0 * speed_multiplier(avg_speed_kph)
    return round(litres * FUEL_KG_CO2E_PER_L[fuel], 3)


def _primary_highway(value) -> str:
    """osmnx may store highway as a string or a list (e.g. "['unclassified', 'residential']")."""
    if isinstance(value, str) and value.startswith("["):
        try:
            value = ast.literal_eval(value)
        except (ValueError, SyntaxError):
            pass
    if isinstance(value, (list, tuple)):
        value = value[0]
    value = str(value).replace("_link", "")
    return value if value in ROAD_SPEED_CAPS else "default"


def edge_speed_kph(edge_data: dict, period: str) -> float:
    """Effective speed = min(graph speed_kph, road-class cap for the period)."""
    cap_peak, cap_off = ROAD_SPEED_CAPS[_primary_highway(edge_data.get("highway", "default"))]
    cap = cap_peak if period.upper() == "PEAK" else cap_off
    try:
        graph_speed = float(edge_data.get("speed_kph", cap))
    except (TypeError, ValueError):
        graph_speed = cap
    return max(min(graph_speed, cap), 3.0)  # floor avoids divide-by-zero style extremes


def edge_co2e_kg(edge_data: dict, vehicle: str, payload_kg: float, period: str = "OFFPEAK") -> float:
    length_km = float(edge_data["length"]) / 1000.0
    return calc_co2e(length_km, payload_kg, vehicle, edge_speed_kph(edge_data, period))


def add_eco_weights(G, vehicle="light_van", payload_kg=500, period="OFFPEAK"):
    """Adds 'co2e_kg' and 'eff_speed_kph' to every edge so NetworkX can route on emissions."""
    for _, _, _, data in G.edges(keys=True, data=True):
        data["eff_speed_kph"] = edge_speed_kph(data, period)
        data["co2e_kg"] = edge_co2e_kg(data, vehicle, payload_kg, period)
    return G


def load_from_db(connection):
    """Optional: refresh constants from Oracle so APEX edits flow into Python.
    connection = an open python-oracledb connection (wallet details come from Member 2)."""
    global FUEL_KG_CO2E_PER_L, SPEED_CORRECTION
    cur = connection.cursor()
    FUEL_KG_CO2E_PER_L = {r[0]: float(r[1]) for r in cur.execute(
        "SELECT fuel_type, kg_co2e_per_litre FROM eco_emission_factors")}
    SPEED_CORRECTION = [(float(a), float(b), float(c)) for a, b, c in cur.execute(
        "SELECT speed_min_kph, speed_max_kph, multiplier FROM eco_speed_correction ORDER BY speed_min_kph")]


def run_self_tests():
    assert calc_co2e(10, 0, "light_van", 40) < calc_co2e(10, 1000, "light_van", 40), "load effect"
    assert calc_co2e(10, 500, "light_van", 8) > calc_co2e(10, 500, "light_van", 40), "congestion effect"
    assert calc_co2e(10, 1000, "rigid_truck_7_5t", 40) > calc_co2e(10, 1000, "light_van", 40), "vehicle size"
    assert calc_co2e(0, 500, "light_van", 40) == 0, "zero distance"
    # Hand-checked: 10 km, empty van, 40 kph -> 10*9/100 = 0.9 L * 2.68 = 2.412 kg
    assert abs(calc_co2e(10, 0, "light_van", 40) - 2.412) < 1e-6, "hand calculation"
    assert _primary_highway("['unclassified', 'residential']") == "unclassified"
    assert _primary_highway("trunk_link") == "trunk"
    print("All emission self-tests passed.")


if __name__ == "__main__":
    run_self_tests()
    # Demo numbers matching the DEMO_SEED rows in Oracle (batch 1, light van, 750 kg)
    s = calc_co2e(22.0, 750, "light_van", 14)
    e = calc_co2e(24.5, 750, "light_van", 32)
    print(f"Shortest: {s} kg | Eco: {e} kg | Saved: {round(s - e, 3)} kg ({round(100 * (s - e) / s, 1)}%)")
