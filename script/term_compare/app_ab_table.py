# Table for app_ab.sh: MiB/s per payload, base against new, medians over rounds.
#   python3 app_ab_table.py <out>/results.jsonl
import json, sys, statistics as st, collections
d = collections.defaultdict(list)
for l in open(sys.argv[1]):
    r = json.loads(l); assert (r['cols'], r['rows']) == (100, 37), r
    app = r['term'].split('_')[0]; d[(app, r['payload'])].append(r['mibs'])
print(f"{'payload':10}{'base':>8}{'new':>8}{'ratio':>7}  n  base min-max  new min-max")
for p in ['ascii', 'unicode', 'latin-ext', 'cyrillic', 'cjk', 'emoji', 'combining', 'box']:
    b, n = d[('base', p)], d[('new', p)]
    print(f"{p:10}{st.median(b):8.1f}{st.median(n):8.1f}{st.median(n)/st.median(b):7.2f}  {len(b)}/{len(n)}  {min(b):.1f}-{max(b):.1f}  {min(n):.1f}-{max(n):.1f}")
