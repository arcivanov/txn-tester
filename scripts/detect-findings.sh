#!/bin/bash
# Translate a tool's findings into an exit code.
#
# None of the bundled tools signal a discovered violation through their own exit
# code: TROC/Fucci run an unbounded `while (true)` loop, only *logging* a
# "BUG REPORT" / "Error: Inconsistent ..." block before continuing until they are
# killed by `timeout`; APTrans only *writes* a check/ artifact tree and then
# exits 0. So the image inspects their output here and turns "a violation was
# found" into a process-able exit code that any caller (buildbot, the standalone
# `docker run`, the smoke test) can act on by reading $?.
#
# Exit codes:
#   0    clean — no findings
#   100  finding — at least one anomaly/inconsistency was detected. An "exotic"
#        code chosen so it cannot be confused with a clean run (0), a tool/infra
#        error (1, 2, ...), or a `timeout` kill (124/143).
#
# Usage:
#   detect-findings.sh troc|fucci  <logfile> [<logfile> ...]
#   detect-findings.sh aptrans     <check-dir> [<check-dir> ...]
set -euo pipefail

# Exotic, easily-detected exit code meaning "a transaction anomaly was found".
FINDING_RC=100

tool="${1:?tool}"
shift

case "$tool" in
    troc | fucci)
        # The "BUG REPORT" block is emitted by BugReport.toString(), which is
        # logged only from the oracle-mismatch branch; the "Error: Inconsistent"
        # lines come from the same path. Either marker means a real finding.
        for f in "$@"; do
            [ -f "$f" ] || continue
            if grep -qE 'BUG REPORT|Error: Inconsistent (query result|final database state)' "$f"; then
                exit "$FINDING_RC"
            fi
        done
        ;;
    aptrans)
        # mysql_check.py's record_details() creates files under check/ only when
        # Checker() flags a case, so any regular file in the tree is a finding.
        for d in "$@"; do
            [ -d "$d" ] || continue
            if [ -n "$(find "$d" -type f -print -quit 2>/dev/null)" ]; then
                exit "$FINDING_RC"
            fi
        done
        ;;
    *)
        echo "detect-findings: unknown tool '$tool'" >&2
        exit 64
        ;;
esac

exit 0
