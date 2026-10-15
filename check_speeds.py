from routing_engine import compare_routes

# (origin, dest, {hour: (min_target, max_target)}) in minutes, car
TESTS = {
    "CBD -> Westlands": ((-1.2864, 36.8172), (-1.2676, 36.8108),
                         {8: (8, 14), 13: (8, 14)}),
    "Mombasa Rd -> Thika Rd": ((-1.3192, 36.8500), (-1.219, 36.887),
                               {8: (22, 35), 13: (20, 32)}),
}

all_ok = True
for label, (a, b, targets) in TESTS.items():
    print(label)
    times = {}
    for hour, (lo, hi) in targets.items():
        f = compare_routes(a, b, "van", 0.8, hour)["fastest"]
        t = f["time_min"]
        times[hour] = t
        ok = lo <= t <= hi
        all_ok = all_ok and ok
        status = "OK" if ok else ("TOO FAST" if t < lo else "TOO SLOW")
        print(f"  hour {hour:2}: {t:5.1f} min (target {lo}-{hi}) "
              f"avg {f['distance_km']/(t/60):4.1f} km/h  {status}")
    ratio_ok = times[8] >= times[13]
    all_ok = all_ok and ratio_ok
    print(f"  peak/off-peak ratio: {times[8]/times[13]:.2f} "
          f"({'OK, peak not faster than off-peak' if ratio_ok else 'PEAK IS FASTER, fix this'})\n")

print("ALL TARGETS MET" if all_ok else "Some targets not met yet, adjust CONGESTION")