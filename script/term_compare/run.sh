#!/bin/bash
# End-to-end throughput: xterm3 example app vs Ghostty vs Alacritty, interleaved.
#   python3 gen.py 64 <dir>                 # payloads, once
#   (cd ../../example && flutter build macos --release -t lib/e2e_bench.dart)
#   ./run.sh <dir> [rounds]                 # appends to <dir>/results.jsonl
# Alacritty from $ALACRITTY or PATH; Ghostty from /Applications.
S=$(cd "$(dirname "$0")" && pwd); W=$(cd "$1" && pwd); R=$W/results.jsonl
P="$W/ascii $W/sgr $W/unicode $W/cursor"
APP=$S/../../example/build/macos/Build/Products/Release/example.app/Contents/MacOS/example
ALACRITTY=${ALACRITTY:-alacritty}
wait_lines() { for i in $(seq 1 300); do [ "$(wc -l < $R 2>/dev/null || echo 0)" -ge $1 ] && return; sleep 1; done; echo "TIMEOUT $2"; }
for round in $(seq 1 ${2:-5}); do
  n=$(cat $R 2>/dev/null | wc -l)
  XB_W=800 XB_H=600 XB_ARGS="$S/drive.py|xterm3|$R|${P// /|}" perl -e 'alarm 300; exec @ARGV' $APP >/dev/null 2>&1
  wait_lines $((n+4)) xterm3
  open -na /Applications/Ghostty.app --args --window-width=100 --window-height=37 --confirm-close-surface=false \
    -e /usr/bin/python3 $S/drive.py ghostty $R $P
  wait_lines $((n+8)) ghostty; pkill -f Ghostty.app/Contents/MacOS/ghostty; sleep 2
  perl -e 'alarm 300; exec @ARGV' $ALACRITTY -o window.dimensions.columns=100 -o window.dimensions.lines=37 \
    -e /usr/bin/python3 $S/drive.py alacritty $R $P >/dev/null 2>&1
  wait_lines $((n+12)) alacritty
done
python3 - "$R" <<'PY'
import json, statistics as st, collections, sys
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    r = json.loads(l); assert (r['cols'], r['rows']) == (100, 37), r; d[(r['payload'], r['term'])].append(r['mibs'])
for k, v in sorted(d.items()): print(*k, f'median={st.median(v):.1f} MiB/s n={len(v)}')
PY
