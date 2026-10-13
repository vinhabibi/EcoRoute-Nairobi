from routing_engine import compare_routes

CBD, WESTLANDS = (-1.2864, 36.8172), (-1.2676, 36.8108)
MOMBASA_RD, THIKA_RD = (-1.3192, 36.8500), (-1.219, 36.887)

for a, b, label in [(CBD, WESTLANDS, "CBD->Westlands"),
                    (MOMBASA_RD, THIKA_RD, "Mombasa Rd->Thika Rd")]:
    r = compare_routes(a, b, "van", 0.8, 8)
    print("\n", label)
    for k in ("shortest", "fastest", "eco"):
        x = r[k]
        print(f"  {k:9} {x['distance_km']:6} km {x['time_min']:6} min {x['fuel_l']:6} L {x['co2_kg']:6} kg")
    print("  savings:", r["savings"])
    assert r["eco"]["co2_kg"] <= r["fastest"]["co2_kg"] + 0.01
    assert r["eco"]["co2_kg"] <= r["shortest"]["co2_kg"] + 0.01
print("\nAll sanity checks passed")