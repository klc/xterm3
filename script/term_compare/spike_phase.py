# spike.sh runs split where the driver finished writing (t0 + accepted, derived;
# both clocks aligned on t0): frames, fps and longest gap while the PTY is still
# being fed (burst) and while the backlog drains (tail). Medians over rounds.
#   python3 spike_phase.py <spike.sh out dir>
# PAYLOADS env: payload list (default ascii unicode cjk).
import json, sys, os, collections, statistics as st
PLS = os.environ.get('PAYLOADS', 'ascii unicode cjk').split()
O = sys.argv[1]; rows = collections.defaultdict(list)
for l in open(f'{O}/results.jsonl'):
    r = json.loads(l); c, n = r['term'].split('#'); rows[(c, n)].append(r)
d = collections.defaultdict(lambda: collections.defaultdict(list))
for (c, n), rs in rows.items():
    p = json.loads(open(f'{O}/prof_{c}_{n}.jsonl').read().strip().splitlines()[-1])
    rep, fr = p['replies'], sorted(x[0] for x in p['frames'])
    for k, r in enumerate(rs, 1):
        t0, t1 = rep[2*k-1][0], rep[2*k][0]; tm = t0 + r['accepted'] * 1e6
        for ph, a, b in (('burst', t0, tm), ('tail', tm, t1)):
            ins = [x for x in fr if a <= x < b]; ts = [a] + ins + [b]
            v = d[(c, r['payload'], ph)]
            v['s'].append((b - a) / 1e6); v['f'].append(len(ins)); v['fps'].append(len(ins) / max((b - a) / 1e6, 1e-9))
            v['gap'].append(max(y - x for x, y in zip(ts, ts[1:])) / 1e3)
M = st.median
print('config        payload  phase   secs frames   fps gap_ms')
for c in dict.fromkeys(c for c, _ in rows):
    for pl in PLS:
        for ph in ['burst', 'tail']:
            v = d[(c, pl, ph)]
            if v['s']: print(f"{c:13s} {pl:8s} {ph:6s}{M(v['s']):6.2f}{M(v['f']):7.0f}{M(v['fps']):6.1f}{M(v['gap']):7.0f}")
