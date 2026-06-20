#!/bin/bash
# Resolve committed git conflict markers by accepting the "theirs" side
# (the lines between '=======' and '>>>>>>>'), discarding the "ours" side
# (the lines between '<<<<<<<' and '=======').
#
# The APTrans upstream (Paper-code-sigmod/APTrans) ships a single commit on main
# with an unresolved, committed three-way merge baked in across ~23 files. In
# every hunk the "theirs" side (commit e2d898d "add APTrans core code") is the
# complete, compiling implementation; the "ours" side is a pre-APTrans stub.
# Accepting theirs everywhere reconstructs the working feature tree and compiles
# cleanly (validated: mvn package -> BUILD SUCCESS).
#
# Usage: accept-theirs.sh <root-dir>
set -euo pipefail

ROOT="${1:?usage: accept-theirs.sh <root-dir>}"

mapfile -t files < <(
    grep -rl -E '^(<<<<<<<|>>>>>>>)' \
        --include='*.java' --include='*.py' --include='*.sh' --include='*.md' \
        "$ROOT" | grep -v '/\.git/' || true
)

if [ "${#files[@]}" -eq 0 ]; then
    echo "accept-theirs: no conflict markers found under $ROOT"
    exit 0
fi

echo "accept-theirs: resolving ${#files[@]} file(s) under $ROOT"
for f in "${files[@]}"; do
    awk '
        /^<<<<<<< /      { inc = 1; keep = 0; next }
        /^=======$/      { if (inc) { keep = 1; next } }
        /^>>>>>>> /      { if (inc) { inc = 0; keep = 0; next } }
        { if (inc) { if (keep) print } else print }
    ' "$f" > "$f.resolved"
    mv "$f.resolved" "$f"
done

remaining=$(grep -rl -E '^(<<<<<<<|=======|>>>>>>>)' \
    --include='*.java' --include='*.py' --include='*.sh' \
    "$ROOT" 2>/dev/null | grep -v '/\.git/' | wc -l || true)
if [ "$remaining" -ne 0 ]; then
    echo "accept-theirs: ERROR: $remaining file(s) still contain conflict markers" >&2
    exit 1
fi
echo "accept-theirs: done, 0 markers remaining"
