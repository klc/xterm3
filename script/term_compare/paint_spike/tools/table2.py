# table2.py OUT [variants]: instrumented copy; per-frame medians of the XProf timers (ms) and counters
import json, sys, glob, os, re, statistics as st, collections
O = sys.argv[1]; d = collections.defaultdict(lambda: collections.defaultdict(list))
for f in sorted(glob.glob(f'{O}/prof_*.jsonl')):
    v = re.match(r'prof_(.+)_(\d+)\.jsonl', os.path.basename(f)).group(1)
    p = json.loads(open(f).read().strip().splitlines()[-1]); k = 1e3 / p['freq']  # ticks -> ms
    rep = p['replies']; t0, t1 = rep[1][0], rep[2][0]
    sb = {s[0]: s for s in p['stats']}; fns = sorted(sb); prev = {fn: fns[i-1] for i, fn in enumerate(fns) if i}
    for x in [x for x in p['frames'] if t0 <= x[0] < t1][3:]:
        fn = x[3]
        if fn not in sb or fn not in prev: continue
        a, b = sb[prev[fn]], sb[fn]; acc = b[10:26]; D = d[v]
        D['build'].append(x[1]/1e3); D['raster'].append(x[2]/1e3)
        D['miss'].append(b[6]-a[6]); D['look'].append(b[5]-a[5]+b[6]-a[6])
        for i, nm in enumerate(['paint','bg','fg','layout','style','builder','build()','layout()','insert']): D[nm].append(acc[i]*k)
        for i, nm in ((9,'draws'),(10,'bgruns'),(11,'clips'),(12,'ligruns'),(13,'ligrej')): D[nm].append(acc[i])
        D['distinct'].append(b[26])
M = st.median
def p90(v): v = sorted(v); return v[int(.9*(len(v)-1))]
cols = ['paint','bg','fg','layout','style','builder','build()','layout()','insert']
print(f"{'variant':10s} {'n':>4s} {'build':>6s} {'p90':>5s} {'rast':>5s} | " + ' '.join(f'{c:>8s}' for c in cols) + ' | look  miss distinct draws bgruns clips ligruns ligrej | us/miss(style+bld+build+lay+ins)')
for v in sys.argv[2:] or sorted(d):
    D = d[v]
    if not D['build']: continue
    mi = sum(D['miss']); per = sum(sum(D[c]) for c in cols[4:]) * 1e3 / max(mi, 1)
    print(f"{v:10s} {len(D['build']):4d} {M(D['build']):6.1f} {p90(D['build']):5.1f} {M(D['raster']):5.1f} | " + ' '.join(f'{M(D[c]):8.2f}' for c in cols) +
          f" | {M(D['look']):4.0f} {M(D['miss']):5.0f} {M(D['distinct']):8.0f} {M(D['draws']):5.0f} {M(D['bgruns']):6.0f} {M(D['clips']):5.0f} {M(D['ligruns']):7.0f} {M(D['ligrej']):6.0f} | {per:5.1f}")
