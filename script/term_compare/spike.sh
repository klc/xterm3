#!/bin/bash
# Starvation spike (throwaway): ascii, unicode and cjk through the example app in
# five configurations, view on, XB_PROF on, 100x37, interleaved rounds.
#   (cd ../../example && flutter build macos --release -t lib/e2e_bench.dart)
#   ./spike.sh <payload dir> <out> [rounds] [configs]
#   python3 spike_table.py <out>
S=$(cd "$(dirname "$0")" && pwd); P=$(cd "$1" && pwd); mkdir -p "$2"; O=$(cd "$2" && pwd); R=$O/results.jsonl
PL="$P/ascii|$P/unicode|$P/cjk"
APP=${APP:-$S/../../example/build/macos/Build/Products/Release/example.app/Contents/MacOS/example}  # APP_OLD=: binary for the paced-old config
for round in $(seq 1 ${3:-3}); do
  for cfg in ${4:-unpaced ack ack-early paced paced+ack isolate isolate-early isolate-push}; do
    pkill -f example.app/Contents/MacOS/example; sleep 2
    E="XB_W=800 XB_H=600 XB_PROF=$O/prof_${cfg}_$round.jsonl"
    case $cfg in
      unpaced) E="$E XB_LEVER=1";; ack) E="$E XB_ACK=1";; ack-early) E="$E XB_ACK=2";; paced) E="$E XB_PACED=1";;
      paced-old) E="$E XB_PACED=1";; paced+ack) E="$E XB_PACED=1 XB_ACK=1";; isolate) E="$E XB_ISO=1";; isolate-early) E="$E XB_ISO=1 XB_ACK=2";; paced-span) E="$E XB_PACED=2";; paced-noframe) E="$E XB_PACED=3";; paced-span11) E="$E XB_PACED=2 XB_BUDGET_MS=11";; isolate-push) E="$E XB_ISO=2";;
    esac
    echo "$(date +%T) round $round $cfg"
    env $E XB_ARGS="$S/drive.py|$cfg#$round|$R|$PL" perl -e 'alarm 900; exec @ARGV' $([ $cfg = paced-old ] && echo "${APP_OLD:?}" || echo "$APP") >/dev/null 2>&1
    echo "$(date +%T) exit $?"
  done
done
