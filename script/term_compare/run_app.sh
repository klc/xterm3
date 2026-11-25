#!/bin/bash
# The example app per payload, three legs per round, interleaved: with TerminalView
# and XB_PROF, without the view (XB_NOVIEW) and XB_PROF, with the view and no
# profiling. Grid 100x37 in every leg.
#   python3 gen.py 64 <dir>                 # payloads, once
#   (cd ../../example && flutter build macos --release -t lib/e2e_bench.dart)
#   ./run_app.sh <dir> <out> [rounds]       # appends to <out>/results.jsonl, prof_<leg>_<round>.jsonl
#   python3 app_table.py <out> <probe.txt>  # the table; probe.txt: see app_table.py
S=$(cd "$(dirname "$0")" && pwd); P=$(cd "$1" && pwd); mkdir -p "$2"; O=$(cd "$2" && pwd); R=$O/results.jsonl
PL="$P/ascii|$P/unicode|$P/latin-ext|$P/cyrillic|$P/cjk|$P/emoji|$P/combining|$P/box"
APP=${APP:-$S/../../example/build/macos/Build/Products/Release/example.app/Contents/MacOS/example}  # APP=, LEGS=, TAG= override
for round in $(seq 1 ${3:-3}); do
  for leg in ${LEGS:-view noview plain}; do
    pkill -f example.app/Contents/MacOS/example; sleep 2
    E="XB_W=800 XB_H=600"
    [ $leg = noview ] && E="$E XB_NOVIEW=1"
    [ $leg != plain ] && E="$E XB_PROF=$O/prof_$TAG${leg}_$round.jsonl"
    echo "$(date +%T) round $round $leg"
    env $E XB_ARGS="$S/drive.py|$TAG$leg#$round|$R|$PL" perl -e 'alarm 900; exec @ARGV' $APP >/dev/null 2>&1
    echo "$(date +%T) exit $?"
  done
done
