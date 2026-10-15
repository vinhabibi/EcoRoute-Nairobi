"""
Unit tests for emissions.py.
Run: python test_emissions.py
"""
from emissions import edge_fuel_l, speed_factor, payload_factor


def test_more_load_more_fuel():
    assert edge_fuel_l(1000, 50, "van", 0.9) > edge_fuel_l(1000, 50, "van", 0.1)


def test_truck_burns_more_than_van():
    assert edge_fuel_l(1000, 50, "truck", 0.5) > edge_fuel_l(1000, 50, "van", 0.5)


def test_speed_factor_lowest_in_efficiency_band():
    # Best efficiency band is 30-60 km/h after aligning with Member 4's model
    assert speed_factor(45) < speed_factor(15)   # vs very slow
    assert speed_factor(45) < speed_factor(90)   # vs very fast
    assert speed_factor(45) == 1.00              # bucket minimum


def test_payload_capped_at_capacity():
    assert payload_factor(5, 1.0) == payload_factor(1, 1.0)


def test_longer_edge_more_fuel():
    assert edge_fuel_l(2000, 50, "van", 0.5) > edge_fuel_l(1000, 50, "van", 0.5)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("passed:", name)