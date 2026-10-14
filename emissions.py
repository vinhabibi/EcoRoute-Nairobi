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

# Speed penalty on fuel consumption per km.
# Bucket table adapted from Maria's ecoroute_emissions.py,
# which is based on fleet-telematics-style fuel-vs-speed curves.
# Best efficiency band is 30-60 km/h; low speeds and high speeds both burn more.
SPEED_BUCKETS = [
    (0,   10, 1.60),
    (10,  20, 1.35),
    (20,  30, 1.15),
    (30,  60, 1.00),
    (60,  80, 1.05),
    (80, 999, 1.20),
]

def speed_factor(v):
    for lo, hi, m in SPEED_BUCKETS:
        if lo <= v < hi:
            return m
    return 1.0

def payload_factor(load_t, capacity_t):
    return 1 + 0.25 * min(load_t / capacity_t, 1.0)

def edge_fuel_l(length_m, speed_kmh, vehicle, load_t):
    p = VEHICLES[vehicle]
    base = p["l_per_100km"] / 100 * (length_m / 1000)
    return base * speed_factor(speed_kmh) * payload_factor(load_t, p["capacity_t"])