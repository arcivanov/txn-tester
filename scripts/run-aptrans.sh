#!/bin/bash
# Runner for APTrans, which is two-phase per isolation level:
#   1) generate test cases OFFLINE with the SQLancer-derived jar (no DB contact)
#   2) execute + check the cases against the REMOTE DBMS via the Python executor
#
# We deliberately bypass the upstream generate.sh / test.sh (they ship with
# committed conflict markers, hardcoded creds/ports, and drive parallelism via
# `screen`). We drive the jar and the Python executor directly with ENV-derived
# args instead.
set -euo pipefail

APTRANS_DIR=/opt/tools/aptrans
SQLANCER_JAR="$APTRANS_DIR/sqlancer/target/sqlancer-2.0.0.jar"

cd "$APTRANS_DIR"

if [ ! -f "$SQLANCER_JAR" ]; then
    echo "ERROR: sqlancer jar not found at $SQLANCER_JAR" >&2
    exit 1
fi

# APTrans has no log file of its own — its entire run trace goes to stdout. Tee
# everything to a file in the output dir so the "log" is evacuated in full too.
exec > >(tee -a "$OUTPUT_SUBDIR/aptrans-console.log") 2>&1

# Evacuate generated cases + anomaly artifacts on exit, however we exit.
evacuate() {
    for d in cases check; do
        if [ -d "$APTRANS_DIR/$d" ]; then
            cp -a "$APTRANS_DIR/$d" "$OUTPUT_SUBDIR/"
            echo "aptrans: saved $APTRANS_DIR/$d -> $OUTPUT_SUBDIR/$d"
        fi
    done
}
trap evacuate EXIT

# Resolve the isolation list.
if [ "${ISOLATION}" = "all" ]; then
    isolations=(serializable repeatable_read read_committed)
else
    isolations=("${ISOLATION}")
fi

# APTrans samples MySQL-family (MySQL/MariaDB/OceanBase) cases with --sample_type mysql.
case "$DB_DBMS" in
    mariadb|mysql|oceanbase) sample_type=mysql ;;
    *) sample_type=mysql ;;
esac

overall_rc=0
for iso in "${isolations[@]}"; do
    echo "==================== APTrans [$iso] ===================="
    cases_path="./cases/${sample_type}/${iso}"

    echo "[$iso] generating ${SAMPLE_NUM} case(s) (offline)"
    java -jar "$SQLANCER_JAR" \
        --sample_type "$sample_type" \
        --save_path "$cases_path" \
        --clean_save_path true \
        --sample_num "$SAMPLE_NUM" \
        --test_isolation "$iso"

    echo "[$iso] checking against ${DB_DBMS} ${DB_HOST}:${DB_PORT}"
    # db_config.py defaults password=123456 and derives port from type when
    # port==0, so we ALWAYS pass explicit --port and --password.
    set +e
    python3 executor/mysql_check.py \
        --host "$DB_HOST" \
        --port "$DB_PORT" \
        --user "$DB_USER" \
        --password "$DB_PASSWORD" \
        --database_type "$DB_DBMS" \
        --database "test_${iso}" \
        --cases_path "$cases_path" \
        --isolation "$iso"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "[$iso] FAILED (exit $rc)" >&2
        overall_rc=$rc
    else
        echo "[$iso] done"
    fi
done

# APTrans records anomalies as files under check/ (it never exits non-zero on a
# finding), so turn a non-empty check/ tree into the exotic finding exit code.
# Only when the run otherwise completed cleanly, so a real error keeps its code.
if [ "$overall_rc" -eq 0 ]; then
    set +e
    /opt/txn-tester/detect-findings.sh aptrans "$APTRANS_DIR/check"
    df_rc=$?
    set -e
    if [ "$df_rc" -ne 0 ]; then
        echo "aptrans: ANOMALY DETECTED (exit $df_rc)" >&2
        overall_rc=$df_rc
    fi
fi

exit "$overall_rc"
