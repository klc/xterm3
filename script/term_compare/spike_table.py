# Table for spike.sh: per config and payload, medians over rounds.
#   python3 spike_table.py <spike.sh out dir>
# mibs: drive.py DSR clock (measured). frames: FrameTimings whose build starts
# inside the payload's DSR window (measured); fps = frames / window (derived).
# gap: longest interval in [window start, frame starts..., window end] (measured).
# backlog: size * (1 - accepted/parsed), bytes not yet parsed when the driver's
# writes returned (derived). rss: max currentRss sampled every 64 PTY chunks in
# the window (measured). pend: max PacedTerminalWriter.pendingChunks (measured).
# snap: isolate request->applied ms median/max, worker build us, UI apply us
# (isolate-push: worker build start->applied). write_s: time inside
# Terminal.write (measured; the worker's for isolate rows); wait% = 1 - write/wall.
# bld_us/ras_us: median per-frame build and raster time of the frames in the window.
# mibs_rng/gap_rng: min-max over rounds.
# kibw: payload KiB / Terminal.write calls in the window (derived). qpkMiB: peak PTY
# bytes queued in the writer (measured, reply index 8, e2e_bench_pty3.dart); '*' =
# pendMax x KiB/write (derived, 1.x binary). parsed_s: drive.py t2-t0 (measured).
# PAYLOADS env: payload list (default ascii unicode cjk).
import json, sys, os, statistics as st, collections
PLS = os.environ.get('PAYLOADS', 'ascii unicode cjk').split()
O = sys.argv[1]
rows = collections.defaultdict(list)
for l in open(f'{O}/results.jsonl'):
    r = json.loads(l)
    assert (r['cols'], r['rows']) == (100, 37), r
    cfg, rnd = r['term'].split('#'); rows[(cfg, rnd)].append(r)
d = collections.defaultdict(lambda: collections.defaultdict(list))
for (cfg, rnd), rs in rows.items():
    p = json.loads(open(f'{O}/prof_{cfg}_{rnd}.jsonl').read().strip().splitlines()[-1])
    rep, fr, sn = p['replies'], sorted(x[0] for x in p['frames']), p.get('snaps', [])
    assert len(rep) == 1 + 2 * len(rs), (cfg, rnd, len(rep))
    for k, r in enumerate(rs, 1):
        a, b = rep[2 * k - 1], rep[2 * k]
        t0, t1 = a[0], b[0]
        inside = [x for x in fr if t0 <= x < t1]
        ts = [t0] + inside + [t1]
        v = d[(cfg, r['payload'])]
        v['mibs'].append(r['mibs']); v['wall'].append((t1 - t0) / 1e6)
        v['frames'].append(len(inside)); v['fps'].append(len(inside) / ((t1 - t0) / 1e6))
        v['gap'].append(max(y - x for x, y in zip(ts, ts[1:])) / 1e3)
        v['write'].append((b[1] - a[1]) / 1e6); v['waitpct'].append(100 * (1 - (b[1] - a[1]) / (t1 - t0)))
        fb = [x for x in p['frames'] if t0 <= x[0] < t1]
        if fb: v['fbuild'].append(st.median(x[1] for x in fb)); v['fraster'].append(st.median(x[2] for x in fb))
        v['acc'].append(r['accepted']); v['backlog'].append(r['size'] / 2**20 * (1 - r['accepted'] / r['parsed']))
        v['chunkKiB'].append(r['size'] / 1024 / max(b[3] - a[3], 1))
        v['pend'].append(b[4]); v['rss'].append(b[5] / 2**20); v['maxrss'].append(b[6] / 2**20)
        v['qMiB'].append(2 * b[7] / 2**20 if len(b) > 7 else 0)  # peak queued, UTF-16 bytes
        v['drain'].append((t1 - t0) / 1e6 - r['accepted'])  # window end minus driver done (derived)
        kibw = r['size'] / 1024 / max(b[2] - a[2], 1); v['kibw'].append(kibw); v['parsed'].append(r['parsed'])
        v['qpk'].append(b[8] / 2**20 if len(b) > 8 else b[4] * kibw / 1024); v['qder'] = len(b) <= 8
        s = [x for x in sn if t0 <= x[3] < t1]
        if s:
            lat = [(x[3] + x[4] - x[0]) / 1e3 for x in s]
            v['latmed'].append(st.median(lat)); v['latmax'].append(max(lat))
            v['build'].append(st.median(x[2] for x in s)); v['apply'].append(st.median(x[4] for x in s))
M = lambda v: st.median(v) if v else float('nan')
print('config        payload  MiB/s  wall_s write_s wait% frames   fps  gap_ms bld_us ras_us | accept_s backlog_MiB chunkKiB pendMax rssMax_MiB qMiB drain_s | snap_ms med/max build_us apply_us  n   mibs_rng     gap_rng   kibw  qpkMiB parsed_s')
for cfg in ['unpaced-old', 'paced-old', 'unpaced', 'paced', 'paced+pause', 'ack', 'ack-early', 'paced+ack', 'isolate', 'isolate-early', 'isolate-push', 'paced-span', 'paced-span11', 'paced-noframe']:
    for pl in PLS:
        v = d[(cfg, pl)]
        if not v['mibs']: continue
        print(f"{cfg:13s} {pl:8s}{M(v['mibs']):6.1f}{M(v['wall']):7.2f}{M(v['write']):8.2f}{M(v['waitpct']):6.0f}{M(v['frames']):7.0f}{M(v['fps']):6.1f}{M(v['gap']):8.0f}{M(v['fbuild']):7.0f}{M(v['fraster']):7.0f} |"
              f"{M(v['acc']):9.2f}{M(v['backlog']):12.1f}{M(v['chunkKiB']):9.2f}{M(v['pend']):8.0f}{M(v['rss']):11.0f}{M(v['qMiB']):5.0f}{M(v['drain']):8.2f} |"
              f"{M(v['latmed']):8.1f}/{M(v['latmax']):<6.1f}{M(v['build']):9.0f}{M(v['apply']):9.0f}  {len(v['mibs'])}"
              f"  {min(v['mibs']):5.1f}-{max(v['mibs']):<5.1f} {min(v['gap']):5.0f}-{max(v['gap']):<5.0f}"
              f"{M(v['kibw']):7.2f}{M(v['qpk']):7.1f}{'*' if v['qder'] else ' '}{M(v['parsed']):8.2f}")
