#!/usr/bin/env bash
# Render PNG ladders from source SVGs.
# Run from repo root: ./src/icons/render.sh

set -euo pipefail

SRC="src/icons"
OUT="www/icons"

# Full experience ladder for the base (root www/icons/) — per c4-conventions §1.
BASE_SIZES=(20 30 40 50 60 70 80 90 100 110 120 130 140 300 512 1024)
# State-icon ladder for per-mode swap targets (matches sizes referenced in driver.xml).
STATE_SIZES=(70 90 300 512 1024)

mkdir -p "$OUT/device/mode_off" "$OUT/device/mode_hold" "$OUT/device/mode_auto"

echo "Rendering base device icons (small=16, large=32) from mode_off..."
rsvg-convert -w 16 -h 16 "$SRC/mode_off.svg" -o "$OUT/device_sm.png"
rsvg-convert -w 32 -h 32 "$SRC/mode_off.svg" -o "$OUT/device_lg.png"

echo "Rendering base experience ladder (default state, uses mode_off art)..."
for size in "${BASE_SIZES[@]}"; do
  rsvg-convert -w "$size" -h "$size" "$SRC/mode_off.svg" -o "$OUT/experience_${size}.png"
done

for mode in off hold auto; do
  echo "Rendering mode_${mode} state ladder..."
  for size in "${STATE_SIZES[@]}"; do
    rsvg-convert -w "$size" -h "$size" "$SRC/mode_${mode}.svg" \
                 -o "$OUT/device/mode_${mode}/experience_${size}.png"
  done
done

echo "Done."
ls -la "$OUT" "$OUT/device/mode_off" "$OUT/device/mode_hold" "$OUT/device/mode_auto"
