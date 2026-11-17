#!/usr/bin/env bash
# Builds the OpenTripPlanner graph for Ireland from public data, measures what the build needs,
# and checks that the new graph answers a known route before anything is published.
#
#   TAG=graph-YYYYMMDD-HHMM ./build.sh
#   TEST_HEAP_MB=6000   optional: cap the transit build heap for a sizing test
#
# Needs docker, osmium-tool, curl and python3 on Linux. Scratch files go to work/, results to out/
# (graph.obj, manifest.json, logs.tar.gz). Exits 0 only when the graph was built and it routes.
set -Eeuo pipefail

OTP_IMAGE=opentripplanner/opentripplanner:2.10.0@sha256:8d54e5c589186707ee365417f2202dc878c451fa3001b8edff07019531100933
GTFS_URL=https://www.transportforireland.ie/transitData/Data/GTFS_All.zip
OSM_URL=https://download.geofabrik.de/europe/ireland-and-northern-ireland-latest.osm.pbf
# Only what routing needs: streets, platforms, park and ride, turn restrictions, route relations.
OSM_FILTER=(w/highway wa/public_transport=platform wa/railway=platform w/park_ride=yes r/type=restriction r/type=route)
# Below the 16 GB of a standard public runner: an overrun ends as exit 137 with logs, not as a lost runner.
CONTAINER_MEM=14g
STREETS_HEAP_MB=8000
TRANSIT_HEAP_MB=${TEST_HEAP_MB:-12000}
SERVE_HEAP_MB=8000
MIN_GRAPH_BYTES=$((300 * 1048576))

[[ ${TAG-} =~ ^graph-[0-9]{8}-[0-9]{4}$ ]] || { echo "TAG must look like graph-YYYYMMDD-HHMM" >&2; exit 2; }
[[ $TRANSIT_HEAP_MB =~ ^[0-9]{3,6}$ ]] || { echo "TEST_HEAP_MB must be a number of megabytes" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$ROOT/work
OUT=$ROOT/out
cpus=$(nproc)
mem_total_mb=$(free -m | awk '$1 == "Mem:" { print $2 }')

summary() { # printed on every exit, pass or fail: the measurements are the point of a sizing run
  python3 -I - "$WORK" "$TAG" "$cpus" "$mem_total_mb" <<'EOF' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" || true
import json, sys
work, tag, cpus, mem = sys.argv[1:5]
cols = ["exit_code", "heap_cap_mb", "seconds", "container_peak_mb", "anon_peak_mb", "full_gcs", "gc_pause_total_s",
        "live_after_full_gc_max_mb", "occupancy_before_gc_max_mb"]
print(f"### Graph build measurements ({tag})\n\nRunner: {cpus} CPUs, {mem} MB of memory\n")
print("| step | " + " | ".join(c.replace("_", " ") for c in cols) + " |")
print("|---" * (len(cols) + 1) + "|")
for step in ("streets", "transit", "serve"):
    try:
        m = json.load(open(f"{work}/m-{step}.json"))
    except OSError:
        print(f"| {step} | not run" + " |" * len(cols))
        continue
    print(f"| {step} | " + " | ".join("-" if m.get(c) is None else str(m[c]) for c in cols) + " |")
EOF
}

die() {
  echo "build: FAILED at $1" >&2
  exit 1
}

peak= anon=
sample() { # sample <container id>: keeps the highest memory the container has used so far (cgroup v2), in MB
  local dir v
  for dir in "/sys/fs/cgroup/system.slice/docker-$1.scope" "/sys/fs/cgroup/docker/$1"; do
    [ -d "$dir" ] || continue
    if read -r v 2>/dev/null <"$dir/memory.peak"; then peak=$((v / 1048576)); fi
    v=$(awk '$1 == "anon" { print $2 }' "$dir/memory.stat" 2>/dev/null || true)
    if [ -n "$v" ] && [ $((v / 1048576)) -gt "${anon:-0}" ]; then anon=$((v / 1048576)); fi
    return 0
  done
}

record() { # record <step> <heap MB> <seconds> <container peak MB> <anon peak MB> <exit code>: adds what the GC log says
  python3 -I - "$WORK/gc-$1.log" "$WORK/m-$1.json" "$@" <<'EOF'
import json, re, sys
gc_log, out, _step, heap, seconds, peak, anon, code = sys.argv[1:9]
full = young = 0
pause = 0.0
live, before = [], []
try:
    for line in open(gc_log, errors="replace"):
        m = re.search(r"Pause (Full|Young).*? (\d+)M->(\d+)M\((\d+)M\) ([\d.]+)ms", line)
        if not m:
            continue
        before.append(int(m[2]))
        pause += float(m[5])
        if m[1] == "Full":
            full += 1
            live.append(int(m[3]))
        else:
            young += 1
except OSError:
    pass
num = lambda s: int(s) if s.isdigit() else None
json.dump({
    "exit_code": num(code), "heap_cap_mb": int(heap), "seconds": int(seconds),
    "container_peak_mb": num(peak), "anon_peak_mb": num(anon),
    "full_gcs": full, "young_gcs": young, "gc_pause_total_s": round(pause / 1000),
    # Live data after a full collection is the floor of what the step needs; occupancy before a collection is the ceiling.
    "live_after_full_gc_max_mb": max(live, default=None), "occupancy_before_gc_max_mb": max(before, default=None),
}, open(out, "w"))
EOF
}

run_step() { # run_step <step> <heap MB> <OTP arguments…>: one OTP run in a container with no network
  local step=$1 heap=$2 t0=$SECONDS id code
  shift 2
  peak= anon=
  id=$(docker run -d --name "otp-$step" --network none --user "$(id -u):$(id -g)" \
    --memory="$CONTAINER_MEM" --memory-swap="$CONTAINER_MEM" \
    -e JAVA_TOOL_OPTIONS="-Xmx${heap}m -XX:+UseCompactObjectHeaders -XX:+UseSerialGC -Xlog:gc:file=/var/opentripplanner/gc-$step.log" \
    -v "$WORK":/var/opentripplanner "$OTP_IMAGE" "$@")
  while [ "$(docker inspect -f '{{.State.Running}}' "otp-$step")" = true ]; do
    sample "$id"
    sleep 2
  done
  code=$(docker inspect -f '{{.State.ExitCode}}' "otp-$step")
  docker logs "otp-$step" >"$WORK/$step.log" 2>&1 || true
  docker rm -f "otp-$step" >/dev/null
  record "$step" "$heap" "$((SECONDS - t0))" "$peak" "$anon" "$code"
  if [ "$code" != 0 ]; then
    echo "--- last lines of the $step log (exit code $code)" >&2
    tail -n 40 "$WORK/$step.log" >&2
    return 1
  fi
}

otp_query() { # otp_query <JSON body>: one GraphQL call to the OTP started by serve_check
  curl -fsS -m 120 -H 'Content-Type: application/json' -d "$1" http://127.0.0.1:8080/otp/gtfs/v1
}

serve_check() { # the new graph must load and answer a known route: Heuston to Connolly, tomorrow 10:00 UTC, with a transit leg
  local t0=$SECONDS id ready=0 code=1 body answer
  peak= anon=
  mkdir "$WORK/serve"
  ln "$WORK/graph.obj" "$WORK/serve/graph.obj"
  id=$(docker run -d --name otp-serve -p 127.0.0.1:8080:8080 --user "$(id -u):$(id -g)" \
    --memory="$CONTAINER_MEM" --memory-swap="$CONTAINER_MEM" \
    -e JAVA_TOOL_OPTIONS="-Xmx${SERVE_HEAP_MB}m -XX:+UseCompactObjectHeaders -Xlog:gc:file=/var/opentripplanner/gc-serve.log" \
    -v "$WORK/serve":/var/opentripplanner "$OTP_IMAGE" --load --serve)
  while [ $((SECONDS - t0)) -lt 300 ] && [ "$(docker inspect -f '{{.State.Running}}' otp-serve)" = true ]; do
    sample "$id"
    if otp_query '{"query":"{ feeds { feedId } }"}' 2>/dev/null | grep -q feedId; then
      ready=1
      break
    fi
    sleep 5
  done
  if [ "$ready" = 1 ]; then
    body=$(python3 -I -c '
import datetime, json
day = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
query = """query Route($origin: PlanLabeledLocationInput!, $destination: PlanLabeledLocationInput!, $dateTime: PlanDateTimeInput) {
  planConnection(origin: $origin, destination: $destination, dateTime: $dateTime, first: 5) {
    routingErrors { code }
    edges { node { legs { mode transitLeg } } }
  }
}"""
at = lambda lat, lon: {"location": {"coordinate": {"latitude": lat, "longitude": lon}}}
print(json.dumps({"query": query, "variables": {
    "origin": at(53.3464, -6.2924), "destination": at(53.3509, -6.25),
    "dateTime": {"earliestDeparture": day + "T10:00:00+00:00"}}}))')
    if answer=$(otp_query "$body") && python3 -I -c '
import json, sys
edges = json.load(sys.stdin)["data"]["planConnection"]["edges"]
sys.exit(0 if any(leg["transitLeg"] for e in edges for leg in e["node"]["legs"]) else 1)' <<<"$answer"; then
      code=0
    else
      echo "serve check: no itinerary with a transit leg: ${answer:0:600}" >&2
    fi
    sample "$id"
  else
    echo "serve check: OTP was not ready within 300 s" >&2
  fi
  docker logs otp-serve >"$WORK/serve.log" 2>&1 || true
  docker rm -f otp-serve >/dev/null
  mv "$WORK/serve/gc-serve.log" "$WORK/gc-serve.log" 2>/dev/null || true
  rm -rf "$WORK/serve"
  record serve "$SERVE_HEAP_MB" "$((SECONDS - t0))" "$peak" "$anon" "$code"
  if [ "$code" != 0 ]; then
    tail -n 40 "$WORK/serve.log" >&2
    return 1
  fi
}

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"
trap summary EXIT

echo "runner: $cpus CPUs, $mem_total_mb MB of memory; transit heap cap ${TRANSIT_HEAP_MB} MB"
free -m
df -h "$ROOT" | tail -n 1

# 1. Timetables. A truncated or corrupted download must not reach the build.
curl -fsSL --retry 3 -m 1800 -D "$WORK/gtfs.headers" -o "$WORK/GTFS_All.zip" "$GTFS_URL" || die gtfs_download
gtfs_etag=$(tr -d '\r"' <"$WORK/gtfs.headers" | awk 'tolower($1) == "etag:" { e = $2 } END { print e }')
zip_report=$(python3 -I -m zipfile -t "$WORK/GTFS_All.zip" 2>&1) || die gtfs_zip
[[ $zip_report != *corrupted* ]] || die gtfs_zip
gtfs_sha=$(sha256sum "$WORK/GTFS_All.zip" | cut -d' ' -f1)
gtfs_bytes=$(stat -c %s "$WORK/GTFS_All.zip")

# 2. Map, filtered down to what routing needs. The raw extract does not stay in the build folder.
curl -fsSL --retry 3 -m 1800 -D "$WORK/osm.headers" -o "$WORK/map.osm.pbf" "$OSM_URL" || die osm_download
osm_modified=$(tr -d '\r' <"$WORK/osm.headers" | awk 'tolower($1) == "last-modified:" { $1 = ""; m = substr($0, 2) } END { print m }')
osm_bytes=$(stat -c %s "$WORK/map.osm.pbf")
osmium tags-filter "$WORK/map.osm.pbf" "${OSM_FILTER[@]}" -o "$WORK/ireland.osm.pbf" -f pbf,add_metadata=false || die osm_filter
rm -f "$WORK/map.osm.pbf" "$WORK/gtfs.headers" "$WORK/osm.headers"
osm_filtered_bytes=$(stat -c %s "$WORK/ireland.osm.pbf")
cp "$ROOT/build-config.json" "$WORK/"

# 3. Streets, then timetables on top of them: two steps, one container each.
run_step streets "$STREETS_HEAP_MB" --buildStreet --save || die streets
run_step transit "$TRANSIT_HEAP_MB" --loadStreet --save || die transit
graph_bytes=$(stat -c %s "$WORK/graph.obj" 2>/dev/null || echo 0)
[ "$graph_bytes" -ge "$MIN_GRAPH_BYTES" ] || die graph_too_small

# 4. Nothing is published unless the graph loads and routes.
serve_check || die serve_check

# 5. Results.
graph_sha=$(sha256sum "$WORK/graph.obj" | cut -d' ' -f1)
mv "$WORK/graph.obj" "$OUT/graph.obj"
tar -czf "$OUT/logs.tar.gz" -C "$WORK" streets.log transit.log serve.log gc-streets.log gc-transit.log gc-serve.log
M_TAG=$TAG M_IMAGE=$OTP_IMAGE M_BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ) M_COMMIT=${GITHUB_SHA-} \
  M_GTFS_URL=$GTFS_URL M_GTFS_ETAG=$gtfs_etag M_GTFS_SHA=$gtfs_sha M_GTFS_BYTES=$gtfs_bytes \
  M_OSM_URL=$OSM_URL M_OSM_MODIFIED=$osm_modified M_OSM_BYTES=$osm_bytes M_OSM_FILTERED_BYTES=$osm_filtered_bytes \
  M_GRAPH_SHA=$graph_sha M_GRAPH_BYTES=$graph_bytes M_CPUS=$cpus M_MEM=$mem_total_mb \
  python3 -I - "$WORK" "$OUT/manifest.json" <<'EOF'
import json, os, sys
work, out = sys.argv[1:3]
E = os.environ
step = lambda name: json.load(open(f"{work}/m-{name}.json"))
json.dump({
    "schema": 1,
    "tag": E["M_TAG"],
    "built_at": E["M_BUILT_AT"],
    "recipe_commit": E["M_COMMIT"],
    "otp_image": E["M_IMAGE"],
    "gtfs": {"url": E["M_GTFS_URL"], "etag": E["M_GTFS_ETAG"], "sha256": E["M_GTFS_SHA"], "bytes": int(E["M_GTFS_BYTES"])},
    "osm": {"url": E["M_OSM_URL"], "last_modified": E["M_OSM_MODIFIED"], "bytes": int(E["M_OSM_BYTES"]),
            "filtered_bytes": int(E["M_OSM_FILTERED_BYTES"])},
    "graph": {"sha256": E["M_GRAPH_SHA"], "bytes": int(E["M_GRAPH_BYTES"])},
    "runner": {"cpus": int(E["M_CPUS"]), "mem_total_mb": int(E["M_MEM"])},
    "streets": step("streets"),
    "transit": step("transit"),
    "serve": step("serve"),
}, open(out, "w"), indent=1)
EOF
echo "build: ok $TAG graph_bytes=$graph_bytes sha256=$graph_sha"
