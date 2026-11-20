#!/bin/sh
# Two builds of the example app, alternated one round at a time (base first on
# odd rounds, new first on even): run_app.sh's `plain` leg, view on, no
# profiling, 100x37. Each build dir holds a copied example.app - keep that name,
# run_app.sh pkills by it.
#   python3 gen.py 64 <dir>                                   # payloads, once
#   ./app_ab.sh <dir> <out> <base build dir> <new build dir> [rounds]   # default 5
#   python3 app_ab_table.py <out>/results.jsonl
# Building the two: BENCHMARKS.md, "Grapheme-join fast paths", "In the app".
S=$(cd "$(dirname "$0")" && pwd)
for r in $(seq 1 ${5:-5}); do
  if [ $((r % 2)) = 1 ]; then o="base new"; else o="new base"; fi
  for b in $o; do
    [ $b = base ] && d=$3 || d=$4
    APP=$d/example.app/Contents/MacOS/example LEGS=plain TAG=${b}_r${r}_ "$S/run_app.sh" "$1" "$2" 1
  done
done
