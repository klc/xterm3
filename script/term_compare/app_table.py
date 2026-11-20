# Joins run_app.sh's drive.py results with the app's XB_PROF dumps; prints
# medians per payload. Decode seconds are not measurable in-app; they come
# from the decode-1k column of a saved unicode_layer_probe run.
#   ulp 5 <dir>/ascii <dir>/unicode ... > probe.txt   (see unicode_layer_probe.dart)
#   python3 app_table.py <run_app.sh out dir> probe.txt
import json, sys, os, glob, statistics as st, collections, re
O = sys.argv[1]
dec = {}  # payload -> decode MiB/s median from Table A
for l in open(sys.argv[2]):
    m = l.split()  # payload decode parser full no-graph decode-1k full-1k
    if len(m) == 7 and m[0] != 'payload': dec[m[0]] = float(m[5])  # decode-1k: the app's chunking
rows = collections.defaultdict(list)  # (leg, round) -> rows in payload order
for l in open(f'{O}/results.jsonl'):
    r = json.loads(l)
    assert (r['cols'], r['rows']) == (100, 37), r
    leg, rnd = r['term'].split('#'); rows[(leg, rnd)].append(r)
d = collections.defaultdict(lambda: collections.defaultdict(list))
for (leg, rnd), rs in rows.items():
    for r in rs: d[(r['payload'], leg)]['mibs'].append(r['mibs'])
    f = f'{O}/prof_{leg}_{rnd}.jsonl'
    if not os.path.exists(f): continue
    p = json.loads(open(f).read().strip().splitlines()[-1])
    rep, fr = p['replies'], p['frames']
    assert len(rep) == 1 + 2 * len(rs), (f, len(rep))
    for k, r in enumerate(rs, 1):
        (t0, w0, c0), (t1, w1, c1) = rep[2 * k - 1], rep[2 * k]
        inside = [x for x in fr if t0 <= x[0] < t1]
        mb = r['size'] / 2**20
        v = d[(r['payload'], leg)]
        v['wall'].append((t1 - t0) / 1e6); v['write'].append((w1 - w0) / 1e6)
        v['build'].append(sum(x[1] for x in inside) / 1e6); v['raster'].append(sum(x[2] for x in inside) / 1e6)
        v['frames'].append(len(inside)); v['chunkKiB'].append(r['size'] / 1024 / max(c1 - c0, 1)); v['decode'].append(mb / dec[r['payload']] if r['payload'] in dec else float('nan'))
    # sanity: frames with timestamps outside every reply window at all
    print(f'{f}: frames={len(fr)} first/last frame vs first/last reply (s): '
          f'{(fr[0][0]-rep[0][0])/1e6 if fr else None:.2f} {(fr[-1][0]-rep[-1][0])/1e6 if fr else 0:.2f}', file=sys.stderr)
M = lambda v: st.median(v) if v else float('nan')
order = ['ascii', 'unicode', 'latin-ext', 'cyrillic', 'cjk', 'emoji', 'combining', 'box']
print('payload     view  noview plain |  wall  write decode(A) build raster frames | movable% build% other% | noview: wall write other% | chunkKiB v/nv  n')
for p in order:
    v, n, pl = d[(p, 'view')], d[(p, 'noview')], d[(p, 'plain')]
    if not v['mibs']: continue
    wall, wr, de, bu = M(v['wall']), M(v['write']), M(v['decode']), M(v['build'])
    nw, nwr, nde = M(n['wall']), M(n['write']), M(n['decode'])
    print(f"{p:10s}{M(v['mibs']):6.1f}{M(n['mibs']):7.1f}{M(pl['mibs']):6.1f} |"
          f"{wall:6.2f}{wr:7.2f}{de:7.2f}{bu:9.2f}{M(v['raster']):7.2f}{M(v['frames']):7.0f} |"
          f"{100*(wr+de)/wall:8.0f}{100*bu/wall:7.0f}{100*(wall-wr-de-bu)/wall:7.0f} |"
          f"        {nw:5.2f}{nwr:6.2f}{100*(nw-nwr-nde)/nw:7.0f} | {M(v['chunkKiB']):5.1f}/{M(n['chunkKiB']):5.1f}  {len(v['mibs'])}/{len(n['mibs'])}/{len(pl['mibs'])}")
