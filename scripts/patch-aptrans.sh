#!/bin/bash
# Patch APTrans's Python executor to stop perturbing server-GLOBAL state.
#
# Upstream init_config() runs `SET GLOBAL innodb_lock_wait_timeout = 1` and
# `SET GLOBAL lock_wait_timeout = 1`, which changes lock-wait behavior for the
# ENTIRE server (every other connection/tool), not just APTrans. APTrans relied
# on GLOBAL so that all the per-transaction connections it opens inherit the
# short timeout.
#
# We make it session-scoped instead:
#   1. init_config: GLOBAL -> SESSION (removes the server-wide side effect).
#   2. create_connection(): set the session timeouts on EVERY connection it
#      hands out, so the transaction sessions keep the short timeout that the
#      GLOBAL setting used to give them.
#
# Each step verifies its anchor so the build fails loudly if upstream drifts.
set -euo pipefail

ROOT="${1:?usage: patch-aptrans.sh <aptrans-root>}"
EXE="$ROOT/executor/executor.py"

[ -f "$EXE" ] || { echo "patch-aptrans: $EXE not found" >&2; exit 1; }

# --- Step 1: GLOBAL -> SESSION in init_config -----------------------------
for var in innodb_lock_wait_timeout lock_wait_timeout; do
    if ! grep -q "SET GLOBAL ${var} = 1" "$EXE"; then
        echo "patch-aptrans: anchor 'SET GLOBAL ${var} = 1' not found" >&2
        exit 1
    fi
    sed -i "s/SET GLOBAL ${var} = 1/SET SESSION ${var} = 1/" "$EXE"
done

# --- Step 2: inject session timeouts into create_connection ---------------
anchor='            return pymysql.connect(**dbconfig)'
if ! grep -qF "$anchor" "$EXE"; then
    echo "patch-aptrans: create_connection anchor not found" >&2
    exit 1
fi
awk '
{
    if ($0 == "            return pymysql.connect(**dbconfig)") {
        print "            conn = pymysql.connect(**dbconfig)"
        print "            # session-scoped (not GLOBAL) so concurrent tools on the same"
        print "            # server are unaffected; preserves APTrans short-lock-wait intent."
        print "            if self.db_config.args.database_type != \"oceanbase\":"
        print "                with conn.cursor() as _cur:"
        print "                    _cur.execute(\"SET SESSION innodb_lock_wait_timeout = 1\")"
        print "                    _cur.execute(\"SET SESSION lock_wait_timeout = 1\")"
        print "                conn.commit()"
        print "            return conn"
    } else {
        print
    }
}' "$EXE" > "$EXE.patched" && mv "$EXE.patched" "$EXE"

# --- Verify ---------------------------------------------------------------
# Scope the check to the two lock-timeout statements we convert; a pre-existing
# COMMENTED `# ... SET GLOBAL TRANSACTION ISOLATION LEVEL ...` line is harmless
# and intentionally left untouched.
if grep -qE 'SET GLOBAL (innodb_lock_wait_timeout|lock_wait_timeout) = 1' "$EXE"; then
    echo "patch-aptrans: ERROR: a 'SET GLOBAL' lock-timeout statement remains" >&2
    grep -nE 'SET GLOBAL (innodb_lock_wait_timeout|lock_wait_timeout) = 1' "$EXE" >&2
    exit 1
fi
if ! grep -q 'SET SESSION innodb_lock_wait_timeout = 1' "$EXE"; then
    echo "patch-aptrans: ERROR: session timeout injection missing" >&2
    exit 1
fi
echo "patch-aptrans: done (no SET GLOBAL remaining; session timeouts injected)"
