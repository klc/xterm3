# table.py OUT [order...]: per variant, pooled over rounds, frames inside the payload window (first 3 dropped)
import json, sys, glob, os, re, statistics as st, collections
O = sys.argv[1]; d = collections.defaultdict(lambda: collections.defaultdict(list))
mibs = collections.defaultdict(list)
for l in open(f'{O}/results.jsonl'):
    r = json.loads(l); mibs[r['payload']].append(r['mibs'])
for f in sorted(glob.glob(f'{O}/prof_*.jsonl')):
    v = re.match(r'prof_(.+)_(\d+)\.jsonl', os.path.basename(f)).group(1)
    p = json.loads(open(f).read().strip().splitlines()[-1])
    rep = p['replies']; t0, t1 = rep[1][0], rep[2][0]
    st_by = {s[0]: s for s in p['stats']}; fns = sorted(st_by)
    prev = {fn: fns[i - 1] for i, fn in enumerate(fns) if i}
    fr = [x for x in p['frames'] if t0 <= x[0] < t1][3:]
    for x in fr:
        fn = x[3]
        if fn not in st_by or fn not in prev: continue
        a, b = st_by[prev[fn]], st_by[fn]
        dd = [b[i] - a[i] for i in range(2, 9)]
        D = d[v]; D['build'].append(x[1] / 1e3); D['raster'].append(x[2] / 1e3)
        D['writes'].append(dd[0]); D['paints'].append(dd[1]); D['lines'].append(dd[2])
        D['look'].append(dd[3] + dd[4]); D['miss'].append(dd[4]); D['glyph'].append(dd[5] + dd[6])
        D['new'].append(a[9] != b[9])
    if p['extra'] if 'extra' in p else False: pass
M = st.median
def p90(v): v = sorted(v); return v[int(.9 * (len(v) - 1))]
order = sys.argv[2:] or sorted(d)
print(f"{'variant':10s} {'n':>4s} {'build':>6s} {'p90':>6s} {'raster':>6s} | {'lookups':>7s} {'misses':>6s} {'miss%':>5s} {'glyph':>5s} {'paints':>6s} {'lines':>5s} {'new%':>4s} {'wr/f':>4s} | MiB/s")
for v in order:
    D = d[v]
    if not D['build']: print(v, 'no frames'); continue
    look, miss = M(D['look']), M(D['miss'])
    print(f"{v:10s} {len(D['build']):4d} {M(D['build']):6.1f} {p90(D['build']):6.1f} {M(D['raster']):6.1f} | {look:7.0f} {miss:6.0f} {100*sum(D['miss'])/max(sum(D['look']),1):5.1f} {M(D['glyph']):5.0f} {M(D['paints']):6.0f} {M(D['lines']):5.0f} {100*sum(D['new'])/len(D['new']):4.0f} {M(D['writes']):4.0f} | {M(mibs[v]):5.1f}")
