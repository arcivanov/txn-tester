#!/bin/bash
# Host-side wrapper for the txn-tester image.
#
# It runs the container AS THE CURRENT USER and mounts a host output directory,
# so that all evacuated logs/artifacts under $OUTPUT_DIR are owned by you (not
# root). The image itself is arbitrary-uid-safe; this wrapper just supplies the
# right `docker run` flags:
#   --user "$(id -u):$(id -g)"        run as the current user
#   -v "<host output dir>:/output"    persist results, owned by you
#   -e OUTPUT_DIR=/output             where the container writes them
#
# Usage:
#   TOOL=troc DB_HOST=10.0.0.5 DB_USER=root DB_PASSWORD=secret ./run.sh
#   OUTPUT_DIR=./results TOOL=aptrans DB_HOST=db ... ./run.sh --network mynet
#
# Any extra arguments are passed through to `docker run` (e.g. --network).
# Recognized tool/connection env vars are forwarded to the container if set.
set -euo pipefail

IMAGE="${TXN_TESTER_IMAGE:-txn-tester}"

# Host directory that receives results (owned by the current user). Inside the
# container this is always mounted at /output. Default: ./output next to CWD.
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/output}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"   # absolute path for the bind mount

# Forward recognized env vars that are actually set in the caller's environment.
forward=()
for v in TOOL MODE DURATION SAMPLE_NUM ISOLATION \
         DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_DBMS DB_TABLE; do
    if [ -n "${!v:-}" ]; then
        forward+=( -e "$v=${!v}" )
    fi
done

set -x
exec docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$OUTPUT_DIR:/output" \
    -e OUTPUT_DIR=/output \
    "${forward[@]}" \
    "$@" \
    "$IMAGE"
