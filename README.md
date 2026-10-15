# EcoRoute Nairobi

**Route planning for delivery fleets that shows the CO₂ cost of every route, not just the time.**

Built on Oracle Autonomous Database and Oracle APEX for the Green Tech Hackathon 2026, Sustainable Transport and Logistics Systems track.

- **Live app:** (https://ecoroute-6jaqemeqkgkkt6rkjzskuv.streamlit.app/)
- **Team:** Root Access, Jomo Kenyatta University of Agriculture and Technology (JKUAT)
- **Track:** Sustainable Transport and Logistics Systems

---

## The problem

Delivery fleets in Nairobi usually take the fastest route by habit. The fastest route is often not the one that burns the least fuel, and most companies have no easy way to measure the emissions of each trip.

## The solution

A dispatcher enters one delivery job: a vehicle, a start, a destination and a payload. EcoRoute returns three routes on real Nairobi roads:

| Route | Optimises for |
| --- | --- |
| Fastest | Travel time |
| Shortest | Distance |
| Eco | CO₂ emitted |

The app shows distance, time and CO₂ for each, draws the fastest (red) and eco (green) routes on a map, and reports how much CO₂ the eco route saves compared with the fastest, next to the time it costs. Dashboards add up the saving across jobs.

Because CO₂ comes from fuel burned, a CO₂ saving is also a diesel saving.

## How it works


```
OpenStreetMap  ->  data/nodes.csv, data/edges.csv  ->  Oracle Autonomous Database
                                                          |  NODES, EDGES, VEHICLES, DELIVERY_JOBS, ROUTE_RESULTS
                                                          |  ECO_ROUTE_PKG (PL/SQL Dijkstra, 3 searches per trip)
                                                          v
                                                    Oracle APEX app on OCI
                                                    (form, comparison tables, map, dashboards)
```


| Component | Description |
| --- | --- |
| Road network | Nairobi roads from OpenStreetMap: 47,524 nodes and 113,063 edges (133 self-loop edges dropped). |
| Named places | The view `V_LOCATION_NODES` matches each place to its nearest road node. Ten places: CBD, Westlands, Kilimani, Karen, Gigiri, Industrial Area, Eastleigh, Donholm, Embakasi, Roysambu. |
| Routing engine | Package `ECO_ROUTE_PKG`: a shortest-path (Dijkstra) search written in PL/SQL, running inside the database. Each trip runs three searches: FASTEST, SHORTEST and ECO. |
| Comparison view | `V_JOB_COMPARISON`: one row per job, with savings measured against the fastest route. |
| Dashboard views | `ECO_V_JOB_SAVINGS`, `ECO_V_JOB_CHART` and `ECO_V_JOB_KPIS`, built over `V_JOB_COMPARISON`. |
| APEX app | Compute Routes page (vehicle, from, to, payload), results tables, route map, and savings dashboards. |
| Python reference engine | An independent implementation of the same routing and emission model, used to cross-check the database results. |

## How CO₂ is calculated

For one road segment:


```
CO2 (kg) = length (km) x base rate (kg/km) x (1 + 0.25 x load) x (1 + 0.25 x (congestion - 1))
```


The CO₂ of a route is the sum over its segments.

- **Base rate:** empty-vehicle kg CO₂ per km, from IPCC 2006 diesel factors (2.68 kg CO₂ per litre). Delivery van: 11 L/100 km = 0.2948 kg/km (capacity 1,000 kg). Light truck: 28 L/100 km = 0.7504 kg/km (capacity 3,000 kg).
- **Load:** payload divided by vehicle capacity, capped at 1. A full vehicle burns 25% more.
- **Congestion:** adds 25% per extra unit above 1.
- **Speed:** does not enter the CO₂ calculation in the Oracle model. It only sets the fastest route's travel time (length divided by speed). In the Python reference engine, speed also affects fuel via a speed-penalty curve validated against Google Maps travel times.

## Results

Savings are CO₂ saved by the eco route against the fastest route, on sample Nairobi trips.

### Demo trips (Oracle KPI view)

| Trip | Fastest | Eco | CO₂ saved |
| --- | --- | --- | --- |
| Westlands to Industrial Area | 9.33 km | 8.29 km | 11.2% |
| Roysambu to Eastleigh | 11.52 km | 10.22 km | 11.3% |
| Embakasi to Industrial Area | 12.66 km | 11.32 km | 10.6% |
| Nairobi CBD to Embakasi | 14.00 km | 12.53 km | 10.5% |
| Karen to Eastleigh (light truck, 1,500 kg) | 25.54 km, 21.56 kg CO₂ | 19.12 km, 16.14 kg CO₂ | 25.1% (5.4 kg, about 2 litres of diesel) |

### Broader sample (Python `evaluate.py`)

Across a wider set of origin–destination pairs sampled in Nairobi:

| Hour | Mean CO₂ saved vs fastest | Range | Mean extra time |
| --- | --- | --- | --- |
| 8 AM (peak) | 5.9% | 0% to 29.4% | ~1.2 min |
| 1 PM (off-peak) | 5.5% | 0% to 28.4% | ~0.9 min |

**Headline: eco routing saves about 5.7% CO₂ on average, up to 29% on the best routes, at a cost of about one extra minute per trip.**

### Cross-validation

The Python reference engine was cross-checked against an independent emission implementation (`ecoroute_emissions.py`) on the Mombasa Road to Thika Road corridor:

- Before alignment: 26.8% divergence between the two engines
- After aligning the speed-penalty curve: 2.0% difference
- Congestion model tuned against Google Maps travel times on two Nairobi corridors, within 20–30%

## Limitations

- **Speeds are static in the Oracle model.** They come from OpenStreetMap road data, with no live traffic. The Python reference engine applies a peak/off-peak congestion model validated against Google Maps.
- **Congestion is 1 on every segment** in the Oracle demo data, so CO₂ there is proportional to distance. In the Python engine, congestion is modelled by road class and time of day.
- **The 25% load factor is a modelling assumption**, not a sourced value. Only the delivery van and light truck rates come from IPCC factors; the medium truck rate is a placeholder.
- **The speed-penalty curve and payload curve in the Python engine are simplified assumptions**, not published curves. 
- **Long trips are slow in the Oracle engine.** The PL/SQL Dijkstra is not yet optimised, so long routes can take minutes. Short trips run quickly.
- **No field measurement yet.** Savings are modelled, not measured against real fleet fuel receipts.

## Next steps

Live congestion data, telematics calibration of the load and speed curves, a faster search, and a single shared emission model across the database and the Python reference tools.

## Repository structure


```
data/        nodes.csv and edges.csv: the Nairobi road network exported from OpenStreetMap
scripts/     export_osm_nairobi.py regenerates the data files
sql/         Oracle backend and views (see below)
*.py         Python reference model, tests and evaluation scripts (see below)
```


### `sql/`

| File | Purpose |
| --- | --- |
| `ecoroute_backend.sql` | Core backend: tables, routing package, comparison view |
| `ecoroute_backend_PATCH_live.sql` | Patch applied to the live database (IPCC-based vehicle rates, load factor, SHORTEST route type) |
| `ecoroute_member4_ALL_IN_ONE.sql` | Dashboard tables and views in a single script |
| `ecoroute_member4_job_views.sql` | Job savings, chart and KPI views |
| `ecoroute_member4_repair_views.sql` | Rebuilds views that failed to compile |

### Python files

A Python implementation of the routing and emission model, used as a reference to cross-check the database results.

| File | Purpose |
| --- | --- |
| `graph_builder.py`, `routing_engine.py` | Build the road graph and compare shortest, fastest and eco routes |
| `emissions.py`, `ecoroute_emissions.py` | Emission model (primary + independent cross-check) |
| `evaluate.py`, `evaluate_savings.py`, `compare_models.py` | Evaluation of savings and comparison of models |
| `check_speeds.py`, `diagnose.py` | Data and speed checks |
| `test_routing.py`, `test_emissions.py` | Sanity tests |

## Setup

Requires an Oracle Autonomous Database with Oracle APEX (OCI).

1. Load `data/nodes.csv` and `data/edges.csv` into the `NODES` and `EDGES` tables.
2. Run `sql/ecoroute_backend.sql`, then `sql/ecoroute_backend_PATCH_live.sql`.
3. Run `sql/ecoroute_member4_ALL_IN_ONE.sql` for the dashboard views.
4. Import the APEX application export: [path to APEX export file].
5. Open the Compute Routes page, choose a vehicle, a start, a destination and a payload, and press **Compute routes**.

To regenerate the data files, run `python scripts/export_osm_nairobi.py`.

Python tests: `python test_routing.py` and `python test_emissions.py`.

## Team

| Name | 
| --- |
| Vincent Kimutai | 
| Tervil Moywaywa | 
| Maria Kanene 
| Lorna Ndanu | 
| Spencer Ngari | 

## Data and attribution

Road network data © OpenStreetMap contributors, available under the Open Database License (ODbL). See https://www.openstreetmap.org/copyright.

Emission factors based on IPCC 2006 Guidelines for National Greenhouse Gas Inventories, cross-checked against UK DEFRA/DESNZ conversion factors.

Congestion model validated against Google Maps travel times on two Nairobi corridors.
