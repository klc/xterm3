# table3.py OUT [variants]: v2 instrumented copy; builder split and per-face miss cost (pooled us/miss)
import json, sys, glob, os, re, statistics as st, collections
O = sys.argv[1]; d = collections.defaultdict(lambda: collections.defaultdict(list)); agg = collections.defaultdict(lambda: [0]*40)
for f in sorted(glob.glob(f'{O}/prof_*.jsonl')):
    v = re.match(r'prof_(.+)_(\d+)\.jsonl', os.path.basename(f)).group(1)
    p = json.loads(open(f).read().strip().splitlines()[-1]); k = 1e6 / p['freq']  # ticks -> us
    rep = p['replies']; t0, t1 = rep[1][0], rep[2][0]
    sb = {s[0]: s for s in p['stats']}; fns = sorted(sb); prev = {fn: fns[i-1] for i, fn in enumerate(fns) if i}
    for x in [x for x in p['frames'] if t0 <= x[0] < t1][3:]:
        fn = x[3]
        if fn not in sb or fn not in prev: continue
        a, b = sb[prev[fn]], sb[fn]; acc = b[10:50]; D = d[v]
        D['build'].append(x[1]/1e3); D['miss'].append(b[6]-a[6]); D['paint'].append(acc[0]*k/1e3)
        for i in range(40): agg[v][i] += acc[i] * (1 if i in (9,10,11,12,13) or (i >= 17 and i < 32 and i % 2 == 1) else k)
M = st.median
print('variant      n build paint  miss | us/miss: ctor push addText build() layout() insert style | per face (b=bold i=italic u=underline): share% layout_us builder_us')
for v in sys.argv[2:] or sorted(d):
    D, A = d[v], agg[v]; mi = sum(D['miss'])
    if not D['build'] or not mi: print(v, len(D['build']), M(D['build']) if D['build'] else '', 'no misses'); continue
    u = lambda i: A[i] / mi
    faces = []
    for bk in range(8):
        c = A[17 + bk*2]
        if c / mi > .02: faces.append(f"{'b' if bk&1 else '-'}{'i' if bk&2 else '-'}{'u' if bk&4 else '-'} {100*c/mi:3.0f}% {A[16+bk*2]/c:5.1f} {A[32+bk]/c:5.1f}")
    print(f"{v:10s} {len(D['build']):3d} {M(D['build']):5.1f} {M(D['paint']):5.1f} {M(D['miss']):5.0f} | {u(5):5.1f} {u(14):5.1f} {u(15):5.1f} {u(6):5.1f} {u(7):5.1f} {u(8):5.1f} {u(4):4.1f} | " + ' | '.join(faces))
