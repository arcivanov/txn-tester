#!/bin/bash
# Shared runner for TROC and Fucci, which expose an identical JCommander CLI and
# the same fat-jar-with-relative-lib layout. Both run an unbounded generate loop
# (no time/iteration flag), so we bound the run with `timeout $DURATION`.
#
# Args: $1 = label (troc|fucci), $2 = tool dir containing target/<name>-*.jar + target/lib/
set -euo pipefail

LABEL="${1:?label}"
TOOL_DIR="${2:?tool dir}"

# The jar manifest Class-Path is relative ("lib/..."), so we must execute with
# CWD = the target/ directory holding both the jar and lib/. Logs (troc.log /
# Fucci.log) are also written to CWD.
cd "$TOOL_DIR/target"

jar=$(ls "${LABEL}"-*.jar 2>/dev/null | head -1)
if [ -z "${jar:-}" ]; then
    echo "ERROR: no ${LABEL}-*.jar found in $TOOL_DIR/target" >&2
    exit 1
fi

echo "Running $LABEL for ${DURATION}s against ${DB_DBMS} ${DB_HOST}:${DB_PORT} (db=$DB_NAME table=$DB_TABLE)"
set +e
timeout --signal=TERM "${DURATION}" \
    java -jar "$jar" \
        --dbms "$DB_DBMS" \
        --host "$DB_HOST" \
        --port "$DB_PORT" \
        --username "$DB_USER" \
        --password "$DB_PASSWORD" \
        --db "$DB_NAME" \
        --table "$DB_TABLE"
rc=$?
set -e

# timeout kills the still-looping fuzzer with rc 124 (or 143 if it exits on TERM):
# that is the normal end of a time-bounded run, not a failure. Any other non-zero
# rc (e.g. a connection failure surfaced before the loop) is a real error.
if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    echo "$LABEL: completed time-bounded run (${DURATION}s)"
    rc=0
elif [ "$rc" -ne 0 ]; then
    echo "$LABEL: FAILED with exit code $rc" >&2
fi

# Evacuate the tool's full log to the output directory. (The full log already
# streams to stdout via log4j's ConsoleAppender; this preserves the file copy,
# which is otherwise lost when the container is removed.)
logfile=$(ls -1 troc.log Fucci.log 2>/dev/null | head -1 || true)
if [ -n "${logfile:-}" ] && [ -f "$logfile" ]; then
    cp -f "$logfile" "$OUTPUT_SUBDIR/"
    echo "$LABEL: saved $(pwd)/$logfile -> $OUTPUT_SUBDIR/$logfile"
else
    echo "$LABEL: WARNING: no log file produced to evacuate" >&2
fi

exit "$rc"
