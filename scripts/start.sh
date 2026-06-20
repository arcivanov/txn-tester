#!/bin/bash
# Entrypoint for the txn-tester image. Dispatches to one of the three bundled
# transaction/isolation bug-detection tools (TROC, Fucci, APTrans), all of which
# connect to a REMOTE DBMS supplied entirely via environment variables. This
# image never builds or starts a database.
#
# Connection (discrete only; no JDBC URL):
#   DB_HOST       default 127.0.0.1
#   DB_PORT       default 3306
#   DB_USER       default root
#   DB_PASSWORD   default "" (empty)
#   DB_NAME       default test       (database to run tests in)
#   DB_DBMS       default mariadb    (target flavor: mariadb | mysql)
#   DB_TABLE      default t          (TROC/Fucci only)
#
# Run control:
#   TOOL          required: troc | fucci | aptrans
#   MODE          full (default) | verify   (verify = fast smoke test)
#   DURATION      TROC/Fucci fuzz seconds   (default 60, verify 15)
#   SAMPLE_NUM    APTrans cases per isolation (default 50, verify 2)
#   ISOLATION     APTrans isolation(s): serializable|repeatable_read|read_committed
#                 or "all" (default). TROC/Fucci ignore this (randomized internally).
#
# Output:
#   OUTPUT_DIR    default /output. The full, unparsed logs/artifacts of the run
#                 are evacuated to a per-tool subdirectory:
#                   $OUTPUT_DIR/troc/    $OUTPUT_DIR/fucci/    $OUTPUT_DIR/APTrans/
#                 Mount it with `-v /host/path:/output` to retrieve results.
set -euo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_DBMS="${DB_DBMS:-mariadb}"
DB_TABLE="${DB_TABLE:-t}"
MODE="${MODE:-full}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
TOOL="${TOOL:-}"

if [ -z "$TOOL" ]; then
    echo "ERROR: TOOL must be set (troc | fucci | aptrans)" >&2
    exit 2
fi
TOOL_LC="$(echo "$TOOL" | tr '[:upper:]' '[:lower:]')"

# Per-tool default DATABASE. TROC and Fucci each run, on startup:
#     DROP DATABASE IF EXISTS <db>; CREATE DATABASE <db>;
# i.e. they OWN and RECREATE their database (and will DESTROY whatever DB_NAME
# points at). So they must default to DISTINCT database names, or sharing one
# makes them race and wipe each other (CREATE DATABASE fails "database exists").
# A distinct table is NOT sufficient — the whole database is dropped. APTrans
# manages its own test_<isolation> databases (see run-aptrans.sh) and ignores
# DB_NAME. Callers may override DB_NAME; point it only at a throwaway database.
case "$TOOL_LC" in
    troc)  DB_NAME="${DB_NAME:-txntest_troc}" ;;
    fucci) DB_NAME="${DB_NAME:-txntest_fucci}" ;;
    *)     DB_NAME="${DB_NAME:-test}" ;;
esac

# Per-tool output subdirectory (exact casing as requested). Created here so the
# runners can evacuate their full logs/artifacts into it.
case "$TOOL_LC" in
    troc)    OUTPUT_SUBDIR="$OUTPUT_DIR/troc" ;;
    fucci)   OUTPUT_SUBDIR="$OUTPUT_DIR/fucci" ;;
    aptrans) OUTPUT_SUBDIR="$OUTPUT_DIR/APTrans" ;;
    *)       OUTPUT_SUBDIR="$OUTPUT_DIR/$TOOL_LC" ;;
esac
mkdir -p "$OUTPUT_SUBDIR"

# Mode-derived defaults
if [ "$MODE" = "verify" ]; then
    DURATION="${DURATION:-15}"
    SAMPLE_NUM="${SAMPLE_NUM:-2}"
    ISOLATION="${ISOLATION:-serializable}"
else
    DURATION="${DURATION:-60}"
    SAMPLE_NUM="${SAMPLE_NUM:-50}"
    ISOLATION="${ISOLATION:-all}"
fi

export DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_DBMS DB_TABLE \
       MODE DURATION SAMPLE_NUM ISOLATION OUTPUT_DIR OUTPUT_SUBDIR

echo "==================== txn-tester ===================="
echo "TOOL=$TOOL MODE=$MODE  target=${DB_DBMS}://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "===================================================="

case "$TOOL_LC" in
    troc)    exec /opt/txn-tester/run-jcommander-tool.sh troc  /opt/tools/troc ;;
    fucci)   exec /opt/txn-tester/run-jcommander-tool.sh fucci /opt/tools/fucci ;;
    aptrans) exec /opt/txn-tester/run-aptrans.sh ;;
    *)
        echo "ERROR: unknown TOOL '$TOOL' (expected troc | fucci | aptrans)" >&2
        exit 2
        ;;
esac
