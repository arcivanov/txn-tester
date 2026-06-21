#!/bin/bash
# Unit test for scripts/detect-findings.sh: verifies that the finding-detection
# logic maps clean output to exit 0 and any anomaly/inconsistency indicator to
# the exotic finding code (100). Runs the script directly on the host (it is
# self-contained and needs no container).
#
# Usage: ./test/detect-findings-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
DETECT="$here/scripts/detect-findings.sh"
FINDING_RC=100

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
check() {
    local desc="$1" expected="$2"
    shift 2
    set +e
    "$DETECT" "$@"
    local rc=$?
    set -e
    if [ "$rc" -eq "$expected" ]; then
        echo "ok   - $desc (exit $rc)"
    else
        echo "FAIL - $desc (expected $expected, got $rc)" >&2
        fail=1
    fi
}

# --- TROC/Fucci: log scanning -------------------------------------------------
# Clean runs: ordinary logs with no violation markers (>=2 lines each).
clean_log="$work/troc-clean.log"
printf 'INFO Create new table.\nINFO Generate new transaction pair.\nINFO Check new schedule.\n' >"$clean_log"
clean_log2="$work/troc-clean2.log"
printf 'INFO Create new table.\nINFO MVCC-based oracle result: ok\nINFO done\n' >"$clean_log2"

# An infrastructural failure log must NOT be mistaken for a finding: a classpath /
# connection error contains neither marker, so it scans clean (the non-zero exit
# code that accompanies it is preserved by the runner, not turned into a finding).
infra_log="$work/troc-infra.log"
printf 'Error: Could not find or load main class troc.Main\nCaused by: java.lang.ClassNotFoundException\n' >"$infra_log"

# A run that found a violation: BugReport.toString() emits "BUG REPORT".
bug_log="$work/troc-bug.log"
printf 'INFO Check new schedule.\nINFO =============================BUG REPORT\nINFO  -- Tx1: ...\n' >"$bug_log"

# The other observed marker, emitted from the same oracle-mismatch path.
inconsistent_log="$work/fucci-inconsistent.log"
printf 'INFO some line\nINFO Error: Inconsistent query result\nINFO another line\n' >"$inconsistent_log"

check "troc: clean log -> 0" 0 troc "$clean_log"
check "troc: BUG REPORT -> finding" "$FINDING_RC" troc "$bug_log"
check "fucci: Inconsistent query result -> finding" "$FINDING_RC" fucci "$inconsistent_log"
# An infra-failure log must scan clean (the runner preserves its real exit code).
check "troc: classpath/infra error log -> 0 (not a finding)" 0 troc "$infra_log"
# Two genuinely clean logs -> clean.
check "fucci: two clean logs -> 0" 0 fucci "$clean_log" "$clean_log2"
# Multiple logs, only one flagged -> finding (order-independent).
check "troc: multiple logs, one flagged -> finding" "$FINDING_RC" troc "$clean_log" "$bug_log"

# --- APTrans: check/ tree inspection -----------------------------------------
empty_check="$work/check-empty"
mkdir -p "$empty_check/SERIALIZABLE/mariadb"   # dirs but no files

found_check="$work/check-found"
mkdir -p "$found_check/REPEATABLE_READ/mariadb/d1" "$found_check/READ_COMMITTED/mariadb/d2"
printf 'pattern:...\n' >"$found_check/REPEATABLE_READ/mariadb/d1/case_0.txt"
printf 'pattern:...\n' >"$found_check/READ_COMMITTED/mariadb/d2/case_1.txt"

missing_check="$work/check-missing"   # never created

check "aptrans: empty check dir -> 0" 0 aptrans "$empty_check"
check "aptrans: missing check dir -> 0" 0 aptrans "$missing_check"
check "aptrans: check dir with files -> finding" "$FINDING_RC" aptrans "$found_check"
check "aptrans: multiple dirs, one with files -> finding" "$FINDING_RC" aptrans "$empty_check" "$found_check"

if [ "$fail" -eq 0 ]; then
    echo "==================== DETECT-FINDINGS TESTS PASSED ===================="
else
    echo "==================== DETECT-FINDINGS TESTS FAILED ====================" >&2
fi
exit "$fail"
