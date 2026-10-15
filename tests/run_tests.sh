#!/usr/bin/env bash
# Offline verification for driver.lua / driver.xml.
#
#   1. Lint: xmllint on driver.xml, luac -p on driver.lua (same as build.sh).
#   2. Run the mock-C4 test suite under LuaJIT (Lua 5.1 semantics — what
#      Director runs) and under stock Lua (5.2+), whichever are installed.
#
# Usage: ./tests/run_tests.sh      (exit status non-zero on any failure)

set -euo pipefail
cd "$(dirname "$0")/.."

echo "== lint"
xmllint --noout driver.xml
LUAC="$(command -v luac || command -v luac5.1 || true)"
[ -n "$LUAC" ] || { echo "luac not found" >&2; exit 1; }
"$LUAC" -p driver.lua
echo "   driver.xml + driver.lua OK"

ran=0
# lua5.1 covers Debian/Ubuntu (CI), where the plain "lua" name may be absent.
interps="luajit lua"
command -v lua >/dev/null 2>&1 || interps="luajit lua5.1"
for interp in $interps; do
  if command -v "$interp" >/dev/null 2>&1; then
    echo "== $interp tests/run.lua"
    "$interp" tests/run.lua
    ran=$((ran + 1))
  fi
done

if [ "$ran" -eq 0 ]; then
  echo "No Lua interpreter found (need luajit and/or lua)." >&2
  exit 1
fi
