#!/usr/bin/env bash
# Entry point of the image built from cloudrun/Dockerfile, meant for a scheduled container job (Google Cloud Run).
# Builds the graph with the OpenTripPlanner installed in the image and, when a bucket is configured, uploads the
# results to it. Nothing is uploaded without GCS_BUCKET, or on a sizing test (TEST_HEAP_MB).
#
#   GCS_BUCKET   optional: name of the Cloud Storage bucket that receives the results
#
# Objects written, the same relative paths as this repository's releases:
#   download/<tag>/graph.obj, download/<tag>/logs.tar.gz, download/<tag>/manifest.json, latest/download/manifest.json
set -Eeuo pipefail
cd "$(dirname "$0")"

TAG=graph-$(date -u +%Y%m%d-%H%M)
TAG=$TAG ./build.sh

if [ -z "${GCS_BUCKET-}" ] || [ -n "${TEST_HEAP_MB-}" ]; then
  echo "run: built $TAG; not published (no bucket configured, or a sizing test)"
  exit 0
fi
[[ $GCS_BUCKET =~ ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$ ]] || { echo "run: GCS_BUCKET is not a bucket name" >&2; exit 2; }

# The job's own short-lived token, from the metadata server. It reaches curl through a file that only this user
# can read: never through a command line, never through the log.
auth=$(mktemp)
trap 'rm -f "$auth"' EXIT
curl -fsS -m 30 --retry 3 -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token |
  python3 -I -c 'import json, sys; print("Authorization: Bearer " + json.load(sys.stdin)["access_token"])' >"$auth"

put() { # put <file> <object name>: streams one file to the bucket
  curl -fsS -m 1800 --retry 3 -o /dev/null -H @"$auth" -T "$1" "https://storage.googleapis.com/$GCS_BUCKET/$2" || {
    echo "run: FAILED to upload $2" >&2
    exit 1
  }
}

# The pointer to the newest build moves last: nobody is sent to a graph that is not fully there.
put out/graph.obj "download/$TAG/graph.obj"
put out/logs.tar.gz "download/$TAG/logs.tar.gz"
put out/manifest.json "download/$TAG/manifest.json"
put out/manifest.json latest/download/manifest.json
echo "run: published $TAG"
