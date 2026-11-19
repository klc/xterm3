#!/bin/bash
# run.sh without Alacritty and with a paced xterm3 leg: xterm3, xterm3 through
# PacedTerminalWriter (XB_PACED=1) and Ghostty, interleaved.
#   python3 gen.py 64 <dir>                 # payloads, once
#   (cd ../../example && flutter build macos --release -t lib/e2e_bench.dart)
#   ./cmp_paced.sh <dir> [rounds]           # appends to <dir>/results.jsonl
# APP=<binary> runs another build (the flutter_pty2 3.x one: spike_pty3.sh);
# TAG= is appended to the xterm3 names; PAUSE=1 adds XB_PAUSE=1 to the paced
# leg, which only the 3.x build reads:
#   APP=<3.x binary> TAG=-pty3 PAUSE=1 ./cmp_paced.sh <dir> [rounds]
S=$(cd "$(dirname "$0")" && pwd); W=$(cd "$1" && pwd); R=$W/results.jsonl
P="$W/ascii $W/sgr $W/unicode $W/cursor"
APP=${APP:-$S/../../example/build/macos/Build/Products/Release/example.app/Contents/MacOS/example}
X=xterm3$TAG; XP=$X-paced; E=XB_PACED=1
[ "$PAUSE" = 1 ] && XP=$XP+pause && E="$E XB_PAUSE=1"
wait_lines() { for i in $(seq 1 300); do [ "$(wc -l < $R 2>/dev/null || echo 0)" -ge $1 ] && return; sleep 1; done; echo "TIMEOUT $2"; }
for round in $(seq 1 ${2:-5}); do
  n=$(cat $R 2>/dev/null | wc -l)
  XB_W=800 XB_H=600 XB_ARGS="$S/drive.py|$X|$R|${P// /|}" perl -e 'alarm 300; exec @ARGV' $APP >/dev/null 2>&1
  wait_lines $((n+4)) $X
  env XB_W=800 XB_H=600 $E XB_ARGS="$S/drive.py|$XP|$R|${P// /|}" perl -e 'alarm 300; exec @ARGV' $APP >/dev/null 2>&1
  wait_lines $((n+8)) $XP
  open -na /Applications/Ghostty.app --args --window-width=100 --window-height=37 --confirm-close-surface=false \
    -e /usr/bin/python3 $S/drive.py ghostty $R $P
  wait_lines $((n+12)) ghostty; pkill -f Ghostty.app/Contents/MacOS/ghostty; sleep 2
done
python3 - "$R" <<'PY'
import json, statistics as st, collections, sys
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    r = json.loads(l); assert (r['cols'], r['rows']) == (100, 37), r; d[(r['payload'], r['term'])].append(r['mibs'])
for k, v in sorted(d.items()): print(*k, f'median={st.median(v):.1f} MiB/s n={len(v)}')
PY
