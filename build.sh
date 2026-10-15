#!/usr/bin/env bash
# Build autoslidingdoor.c4z from repo contents.
# Usage: ./build.sh

set -euo pipefail

NAME="autoslidingdoor"
OUT="${NAME}.c4z"

cd "$(dirname "$0")"

# Debian/Ubuntu's lua5.1 package may only install "luac5.1" (e.g. in CI).
LUAC="$(command -v luac || command -v luac5.1 || true)"
if [ -z "$LUAC" ]; then echo "luac not found (brew install lua / apt install lua5.1)" >&2; exit 1; fi

echo "Pre-flight validation..."
xmllint --noout driver.xml
"$LUAC" -p driver.lua
echo "  driver.xml + driver.lua OK"

echo "Cleaning previous artifact..."
rm -f "${OUT}"

echo "Packaging ${OUT}..."
zip -rq "${OUT}" driver.xml driver.lua www/ \
  -x '*.DS_Store' '.*' 'www/icons/*.svg'

echo "Done. Contents:"
unzip -l "${OUT}" | tail -20

echo ""
echo "Built ${OUT} ($(du -h ${OUT} | cut -f1))"
