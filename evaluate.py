import random, itertools
import pandas as pd
from routing_engine import compare_routes

LANDMARKS = {
    "CBD": (-1.2864, 36.8172), "Westlands": (-1.2676, 36.8108),
    "Industrial Area": (-1.307, 36.853), "Upper Hill": (-1.299, 36.815),
    "Eastleigh": (-1.274, 36.848), "Kilimani": (-1.290, 36.785),
    "Parklands": (-1.263, 36.817), "South B": (-1.310, 36.833),
}

random.seed(42)
pairs = random.sample(list(itertools.permutations(LANDMARKS, 2)), 25)
rows = []
for a, b in pairs:
    for hour in (8, 13):  # peak and off-peak
        r = compare_routes(LANDMARKS[a], LANDMARKS[b], "van", 0.8, hour)
        rows.append({"origin": a, "dest": b, "hour": hour,
                     "shortest_co2": r["shortest"]["co2_kg"],
                     "fastest_co2": r["fastest"]["co2_kg"],
                     "eco_co2": r["eco"]["co2_kg"],
                     "eco_extra_min": round(r["eco"]["time_min"] - r["fastest"]["time_min"], 2),
                     "save_vs_fastest_pct": r["savings"]["co2_vs_fastest_pct"],
                     "save_vs_shortest_pct": r["savings"]["co2_vs_shortest_pct"]})

df = pd.DataFrame(rows)
df.to_csv("results.csv", index=False)
print(df.groupby("hour")[["save_vs_fastest_pct", "save_vs_shortest_pct", "eco_extra_min"]]
        .agg(["mean", "min", "max"]).round(1))