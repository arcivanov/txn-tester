#!/bin/bash
# Smoke test for the txn-tester image: verifies the image actually works by
# running each tool (verify mode) against a throwaway MariaDB and asserting it
# exits 0 and evacuates output to its per-tool subdir.
#
# Host-side / CI script (NOT copied into the image). Requires docker.
#
# Usage:
#   docker build -t txn-tester .
#   ./test/smoke-test.sh
#   TXN_TESTER_IMAGE=ghcr.io/arcivanov/txn-tester:latest ./test/smoke-test.sh
set -euo pipefail

IMAGE="${TXN_TESTER_IMAGE:-txn-tester}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:lts}"
# Run as the caller's own uid/gid (which owns the mounted output dir), exactly as
# run.sh does. The image has no /etc/passwd entry for this uid, so this also
# exercises the arbitrary-user path that CI hits.
TEST_UID="${TEST_UID:-$(id -u)}"
TEST_GID="${TEST_GID:-$(id -g)}"
SUFFIX="$$"
NET="txn-smoke-net-$SUFFIX"
DB="txn-smoke-db-$SUFFIX"
OUT="$(mktemp -d)"

cleanup() {
    docker rm -f "$DB" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$OUT" 2>/dev/null || true
}
trap cleanup EXIT

echo "smoke: image=$IMAGE  mariadb=$MARIADB_IMAGE  output=$OUT"
docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" \
    -e MARIADB_ROOT_PASSWORD=secret "$MARIADB_IMAGE" >/dev/null

echo "smoke: waiting for MariaDB..."
ready=
for _ in $(seq 1 60); do
    if docker exec "$DB" mariadb -uroot -psecret -e "SELECT 1" >/dev/null 2>&1; then
        ready=1; break
    fi
    sleep 2
done
[ -n "$ready" ] || { echo "smoke: FAIL — MariaDB never became ready" >&2; exit 1; }

rc=0
for tool in troc fucci aptrans; do
    echo "==================== smoke: $tool ===================="
    if ! docker run --rm --network "$NET" --user "$TEST_UID:$TEST_GID" \
            -v "$OUT:/output" \
            -e TOOL="$tool" -e MODE=verify \
            -e DB_HOST="$DB" -e DB_USER=root -e DB_PASSWORD=secret \
            "$IMAGE"; then
        echo "smoke: FAIL — $tool exited non-zero" >&2
        rc=1
        continue
    fi
    # Assert the tool evacuated its expected primary artifact.
    case "$tool" in
        troc)    artifact="$OUT/troc/troc.log" ;;
        fucci)   artifact="$OUT/fucci/Fucci.log" ;;
        aptrans) artifact="$OUT/APTrans/aptrans-console.log" ;;
    esac
    if [ -s "$artifact" ]; then
        echo "smoke: OK — $tool produced ${artifact#$OUT/}"
    else
        echo "smoke: FAIL — $tool did not evacuate $artifact" >&2
        rc=1
    fi
done

if [ "$rc" -eq 0 ]; then
    echo "==================== SMOKE PASSED ===================="
else
    echo "==================== SMOKE FAILED ====================" >&2
fi
exit "$rc"
