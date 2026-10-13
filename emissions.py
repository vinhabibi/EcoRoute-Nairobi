EF_KG_PER_L = {"diesel": 2.68, "petrol": 2.31}

# ASSUMPTIONS: replace with sourced values (GLEC / DEFRA)
VEHICLES = {
    "van":   {"fuel": "diesel", "l_per_100km": 11, "capacity_t": 1.0},
    "truck": {"fuel": "diesel", "l_per_100km": 28, "capacity_t": 10.0},
}

def speed_factor(v_kmh):
    v = max(v_kmh, 5)
    return 1 + 0.0004 * (v - 65) ** 2

def payload_factor(load_t, capacity_t):
    return 1 + 0.25 * min(load_t / capacity_t, 1.0)

def edge_fuel_l(length_m, speed_kmh, vehicle, load_t):
    p = VEHICLES[vehicle]
    base = p["l_per_100km"] / 100 * (length_m / 1000)
    return base * speed_factor(speed_kmh) * payload_factor(load_t, p["capacity_t"])