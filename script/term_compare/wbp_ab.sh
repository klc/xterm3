#!/bin/sh
# Two builds of script/write_budget_probe.dart, alternated one pass at a time
# (base first on odd passes, new first on even), then a markdown table of
# medians, min-max, speedup and ns/byte saved.
#   ./wbp_ab.sh <wbp-base> <wbp-new> <passes> <log> <modes> <dir>/sgr <dir>/cursor ...
A=$1; B=$2; N=$3; LOG=$4; MODES=$5; shift 5
: > "$LOG"
for r in $(seq 1 $N); do
  if [ $((r % 2)) = 1 ]; then o="base new"; else o="new base"; fi
  for b in $o; do
    [ $b = base ] && bin=$A || bin=$B
    "$bin" 1 --modes=$MODES "$@" | grep '^S ' | sed "s|^|$b |" >> "$LOG"
  done
done
python3 - "$LOG" "$@" <<'PY'
import sys, os, statistics as st, collections
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    b, _, name, mode, sec = l.split(); d[(b, name, mode)].append(float(sec))
size = {os.path.basename(p): os.path.getsize(p) / 2**20 for p in sys.argv[2:]}
print('| payload | mode | base MiB/s (min-max) | new MiB/s (min-max) | speedup | Δ ns/B | n |'); print('|---|---|---|---|---|---|---|')
keys = []
for (b, name, mode) in d:
    if (name, mode) not in keys: keys.append((name, mode))
for name, mode in keys:
    m = size[name]; bs, ns = d[('base', name, mode)], d[('new', name, mode)]
    mb = [m / s for s in bs]; mn = [m / s for s in ns]
    sb, sn = st.median(bs), st.median(ns)
    print(f'| {name} | {mode} | {m/sb:.1f} ({min(mb):.1f}-{max(mb):.1f}) | {m/sn:.1f} ({min(mn):.1f}-{max(mn):.1f}) | {sb/sn:.3f}x | {(sn-sb)*1e9/(m*2**20):+.2f} | {len(bs)} |')
PY
