#!/bin/sh
# Grid digests of every corpus file in four configurations (100x37 and 7x10, mode
# 2027 on and off), from two builds of script/grapheme_grid_dump.dart; prints how
# many files differ per configuration and the first few names.
#   python3 gen.py 4 <pay> && python3 gen_synthetic.py 4 <pay>   # >= 3 MiB each
#   python3 gen_corpus.py <pay> <pay> <corpus>
#   ./grid_oracle.sh <corpus> <dump-base> <dump-new> <out>
# <out>/base and <out>/new keep the digests. Building <dump-base>: BENCHMARKS.md,
# "Grapheme-join fast paths".
C=$1; O=$4; mkdir -p "$O/base" "$O/new"
for side in base new; do
  [ $side = base ] && B=$2 || B=$3
  "$B" --cols 100 --rows 37 "$C"/* > "$O/$side/w100-g.txt"
  "$B" --cols 100 --rows 37 --no-graph "$C"/* > "$O/$side/w100-n.txt"
  "$B" --cols 7 --rows 10 "$C"/* > "$O/$side/w7-g.txt"
  "$B" --cols 7 --rows 10 --no-graph "$C"/* > "$O/$side/w7-n.txt"
done
for c in w100-g w100-n w7-g w7-n; do
  d=$(diff "$O/base/$c.txt" "$O/new/$c.txt" | grep '^>')
  echo "$c: $(printf '%s' "$d" | grep -c '^>') files differ $(printf '%s\n' "$d" | cut -d' ' -f2 | head -6 | tr '\n' ' ')"
done
