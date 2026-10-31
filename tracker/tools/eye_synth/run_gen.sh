#!/bin/bash
# 4 x 10000 samples in parallel, logs next to the data
# where the data goes (about 470 MB per 40k samples), first argument
OUT=${1:?output dir}
SEED0=${2:-0}
mkdir -p "$OUT"
PY=$(dirname "$0")/../../.venv/bin/python
for s in 1 2 3 4; do
  "$PY" "$(dirname "$0")/gen.py" "$OUT" --n 10000 --seed $((s + SEED0)) > "$OUT/gen_$s.log" 2>&1 &
done
wait
