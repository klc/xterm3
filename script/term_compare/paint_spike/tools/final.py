# final.py ROOT: candidate x payload -> build med/p90, raster med/p90, layouts/frame (mean, acc[7]; stock: misses), late-half build/raster, max RSS
import json, sys, glob, os, re, statistics as st, collections
R = sys.argv[1]
M = st.median
def p90(v): v = sorted(v); return v[int(.9*(len(v)-1))]
def load(d):
    out = collections.defaultdict(lambda: collections.defaultdict(list)); bad = []
    for f in sorted(glob.glob(f'{d}/prof_*.jsonl')):
        v = re.match(r'prof_(.+)_(\d+)\.jsonl', os.path.basename(f)).group(1)
        p = json.loads(open(f).read().strip().splitlines()[-1]); rep = p['replies']
        if len(rep) != 3: bad.append(os.path.basename(f))
        t0, t1 = rep[1][0], rep[2][0]
        sb = {s[0]: s for s in p['stats']}; fns = sorted(sb); prev = {fn: fns[i-1] for i, fn in enumerate(fns) if i}
        D = out[v]; D['rss'].append(rep[2][6] / 2**20)
        fr = [x for x in p['frames'] if t0 <= x[0] < t1][3:]
        for j, x in enumerate(fr):
            fn = x[3]
            if fn not in sb or fn not in prev: continue
            a, b = sb[prev[fn]], sb[fn]
            D['build'].append(x[1]/1e3); D['raster'].append(x[2]/1e3)
            lay = b[17] if len(b) > 17 else b[6]-a[6]
            D['lay'].append(lay)
            if len(b) > 26: D['keys'].append(b[26]); D['allkeys'].append(b[27])
            if j >= len(fr) // 2: D['lb'].append(x[1]/1e3); D['lr'].append(x[2]/1e3)
    return out, bad
order = sys.argv[3].split(',') if len(sys.argv) > 3 else None
cands = sys.argv[2].split(',') if len(sys.argv) > 2 else sorted(os.listdir(R))
data = {c: load(f'{R}/{c}') for c in cands if os.path.isdir(f'{R}/{c}')}
pays = order or sorted({v for c in data for v in data[c][0]})
print(f"{'payload':15s} {'cand':8s} {'n':>4s} | {'build':>5s} {'p90':>5s} | {'rast':>5s} {'p90':>5s} | {'lay/f':>6s} {'med':>5s} | {'lateB':>5s} {'lateR':>5s} | {'RSS':>4s}")
for v in pays:
    for c in cands:
        if c not in data or v not in data[c][0]: continue
        D = data[c][0][v]
        if not D['build']: print(v, c, 'no frames'); continue
        extra = f" keys {M(D['keys']):.0f} cum {max(D['allkeys'])}" if D['keys'] and max(D['allkeys']) else ''
        print(f"{v:15s} {c:8s} {len(D['build']):4d} | {M(D['build']):5.1f} {p90(D['build']):5.1f} | {M(D['raster']):5.1f} {p90(D['raster']):5.1f} | {st.mean(D['lay']):6.0f} {M(D['lay']):5.0f} | {M(D['lb']):5.1f} {M(D['lr']):5.1f} | {max(D['rss']):4.0f}{extra}")
    print()
for c in data:
    if data[c][1]: print('BAD REPLIES', c, data[c][1])
