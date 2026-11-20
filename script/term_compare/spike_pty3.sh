#!/bin/bash
# flutter_pty2 1.x vs 3.x (throwaway): spike.sh with a payload list and one binary
# per config, interleaved rounds, view on, XB_PROF on, 100x37.
#   APP=<3.x example binary> APP_OLD=<1.x example binary> PAYLOADS="ascii unicode cjk sgr" \
#     ./spike_pty3.sh <payload dir> <out> [rounds] [configs]
#   PAYLOADS="ascii unicode cjk sgr" python3 spike_table.py <out>
# The two binaries, from the repo root. The 3.x entrypoint lives in pty3/, outside
# example/, because the example depends on flutter_pty2 ^1.0.0; it is copied in for
# the build and removed again. Each .app is copied aside under its own dir but keeps
# the name example.app, which this script pkills by.
#   (cd example && flutter build macos --release -t lib/e2e_bench.dart)
#   mkdir -p /tmp/pty1 && cp -R example/build/macos/Build/Products/Release/example.app /tmp/pty1/
#   cp script/term_compare/pty3/e2e_bench_pty3.dart example/lib/
#   printf 'dependency_overrides:\n  flutter_pty2:\n    path: <flutter_pty2 3.x checkout>\n' \
#     > example/pubspec_overrides.yaml
#   (cd example && flutter build macos --release -t lib/e2e_bench_pty3.dart)
#   mkdir -p /tmp/pty3 && cp -R example/build/macos/Build/Products/Release/example.app /tmp/pty3/
#   rm example/lib/e2e_bench_pty3.dart example/pubspec_overrides.yaml
#   git checkout example/pubspec.lock && (cd example && flutter pub get)
#   APP=/tmp/pty3/example.app/Contents/MacOS/example APP_OLD=/tmp/pty1/example.app/Contents/MacOS/example ...
S=$(cd "$(dirname "$0")" && pwd); P=$(cd "$1" && pwd); mkdir -p "$2"; O=$(cd "$2" && pwd); R=$O/results.jsonl
PL=$(for p in ${PAYLOADS:-ascii unicode cjk sgr}; do printf '|%s' "$P/$p"; done)
for round in $(seq 1 ${3:-5}); do
  for cfg in ${4:-unpaced-old paced-old unpaced paced paced+pause}; do
    pkill -f example.app/Contents/MacOS/example; sleep 2
    E="XB_W=800 XB_H=600 XB_PROF=$O/prof_${cfg}_$round.jsonl"; A=${APP:?}
    case $cfg in
      unpaced-old) E="$E XB_LEVER=1"; A=${APP_OLD:?};; paced-old) E="$E XB_PACED=1"; A=${APP_OLD:?};;
      unpaced) E="$E XB_LEVER=1";; paced) E="$E XB_PACED=1";; paced+pause) E="$E XB_PACED=1 XB_PAUSE=1";;
    esac
    echo "$(date +%T) round $round $cfg"
    env $E XB_ARGS="$S/drive.py|$cfg#$round|$R$PL" perl -e 'alarm 900; exec @ARGV' $A >/dev/null 2>&1
    echo "$(date +%T) exit $?"
  done
done
