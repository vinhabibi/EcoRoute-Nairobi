# Emission factors, kg CO2 per litre of fuel (tank-to-wheel / combustion only)
# Derived from IPCC 2006 Guidelines, Vol. 2 Energy, default factors:
#   diesel 74,100 kg CO2/TJ, motor gasoline 69,300 kg CO2/TJ,
#   converted using typical net calorific value and density.
# Cross-check: DEFRA/DESNZ conversion factors (100% mineral diesel / petrol rows).
EF_KG_PER_L = {
    "diesel": 2.68,
    "petrol": 2.31,
}

# Vehicle fuel consumption: modelling ASSUMPTIONS, not from a published dataset.
# Typical values for a light diesel van and a rigid delivery truck.
VEHICLES = {
    "van":   {"fuel": "diesel", "l_per_100km": 11, "capacity_t": 1.0},
    "truck": {"fuel": "diesel", "l_per_100km": 28, "capacity_t": 10.0},
}

# speed_factor and payload_factor below are simplified model assumptions,
# not published emission curves.
def speed_factor(v_kmh):
    v = max(v_kmh, 5)
    return 1 + 0.0004 * (v - 65) ** 2

def payload_factor(load_t, capacity_t):
    return 1 + 0.25 * min(load_t / capacity_t, 1.0)

def edge_fuel_l(length_m, speed_kmh, vehicle, load_t):
    p = VEHICLES[vehicle]
    base = p["l_per_100km"] / 100 * (length_m / 1000)
    return base * speed_factor(speed_kmh) * payload_factor(load_t, p["capacity_t"])