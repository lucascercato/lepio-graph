# lepio-graph

Nightly build of an [OpenTripPlanner](https://www.opentripplanner.org/) routing graph for Ireland, made only from public data.

## What happens each night

1. `build.sh` downloads the Transport for Ireland timetables (GTFS) and the OpenStreetMap extract for Ireland and Northern Ireland.
2. It builds the street graph, then the full graph with the timetables, using a pinned OpenTripPlanner image.
3. It starts OpenTripPlanner with the new graph and asks for a known route. A graph that does not route is not published.
4. The result is published as a release.

Each release contains:

| File | What it is |
|---|---|
| `graph.obj` | The OpenTripPlanner graph. It only loads in the exact OpenTripPlanner version named in the manifest. |
| `manifest.json` | Build time, input and output checksums, the OpenTripPlanner image, and how much memory and time each step used. |
| `logs.tar.gz` | OpenTripPlanner and garbage collector logs of the build. |

The last three builds are kept. `status/last-build.json` and `status/builds.csv` hold the record of each night.

## Running it yourself

On Linux with Docker, `osmium-tool`, `curl` and `python3`:

```sh
TAG=graph-$(date -u +%Y%m%d-%H%M) ./build.sh
```

The build needs a machine with 16 GB of memory.

## Data sources and licences

- **Timetables:** Transport for Ireland / National Transport Authority GTFS data, licensed under the [Creative Commons Attribution 4.0 International licence (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/). Contains Irish Public Sector Data (Transport for Ireland).
- **Map:** © [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors, downloaded from [Geofabrik](https://download.geofabrik.de/), or from [openstreetmap.fr](https://download.openstreetmap.fr/extracts/) when Geofabrik cannot be reached (the manifest says which). OpenStreetMap data is available under the [Open Database Licence (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).

The street network inside `graph.obj` is derived from OpenStreetMap data and is made available under the ODbL 1.0. The timetable data inside it remains under CC BY 4.0.

## No warranty

These files are provided as they are, with no guarantee that they are complete, correct or up to date. Always check times with the transport operator.
