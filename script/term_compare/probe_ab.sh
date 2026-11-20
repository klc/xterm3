#!/bin/sh
# Two builds of script/unicode_layer_probe.dart, alternated one round at a time
# (base first on odd passes, new first on even), then medians side by side.
#   python3 gen.py 64 <dir> && python3 gen_synthetic.py 32 <dir>
#   ./probe_ab.sh <ulp-base> <ulp-new> <passes> <log> <dir>/ascii <dir>/unicode ...
# Building <ulp-base>: BENCHMARKS.md, "Grapheme-join fast paths".
A=$1; B=$2; N=$3; LOG=$4; shift 4
: > "$LOG"
for r in $(seq 1 $N); do
  if [ $((r % 2)) = 1 ]; then o="base new"; else o="new base"; fi
  for b in $o; do
    [ $b = base ] && bin=$A || bin=$B
    "$bin" 1 "$@" | grep '^round' | sed "s|^|$b |" >> "$LOG"
  done
done
python3 - "$LOG" <<'PY'
import sys, statistics as st, collections
d = collections.defaultdict(list); order = []
for l in open(sys.argv[1]):
    f = l.split(); b, name, mode, v = f[0], f[3], f[4], float(f[5])
    d[(b, name, mode)].append(v)
    if name not in order: order.append(name)
n = len(d[('base', order[0], 'full')])
print(f"medians MiB/s, n={n} interleaved passes, 100x37, 64 KiB chunks")
print(f"{'payload':18}{'parser':>8}{'full base':>11}{'full new':>10}{'ratio':>7}{'nograph base':>14}{'nograph new':>13}")
for nm in order:
    m = lambda b, k: st.median(d[(b, nm, k)])
    print(f"{nm:18}{m('new','parser'):8.0f}{m('base','full'):11.1f}{m('new','full'):10.1f}{m('new','full')/m('base','full'):7.2f}{m('base','no-graph'):14.1f}{m('new','no-graph'):13.1f}")
PY
