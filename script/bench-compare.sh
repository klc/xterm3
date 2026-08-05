#!/usr/bin/env bash
#
# Interleaved A/B benchmark: this working tree against an older commit.
#
#   script/bench-compare.sh [baseline-ref] [rounds]
#
# Default baseline is 8d938de, the head of SoFluffyOS/xterm2 master - so the
# default run answers "what did the commits since the published repo do".
#
# The baseline is checked out into a git worktree and driven by *this* tree's
# `example/lib/benchmark.dart`, so both sides run byte-identical harness code
# against different library code. The only file that differs is
# `example/lib/bench/bench_stats.dart`, which is replaced by its stub on the
# baseline side because `TerminalRenderStats` did not exist yet.
#
# Runs alternate baseline/head, `rounds` times each. Sequential runs drift -
# BENCHMARKS.md records `fullscreen` climbing monotonically across an
# afternoon of them - and interleaving is what cancels that out.
#
# Close everything else first. The noise band is +-0.5ms on p50; anything else
# on the GPU will swamp the difference being measured.

set -euo pipefail

BASELINE_REF="${1:-8d938de}"
ROUNDS="${2:-3}"
DEVICE="${BENCH_DEVICE:-macos}"
# The grid both builds are held to. Cell count drives every cost in the paint
# path, so this is the knob that decides how much of the frame budget the
# measurement actually occupies.
COLS="${BENCH_COLS:-100}"
ROWS="${BENCH_ROWS:-37}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BASELINE_SHA="$(git rev-parse --short "$BASELINE_REF")"
HEAD_SHA="$(git rev-parse --short HEAD)"

if [ "$BASELINE_SHA" = "$HEAD_SHA" ]; then
  echo "baseline and HEAD are the same commit ($HEAD_SHA); nothing to compare" >&2
  exit 1
fi

WORKTREE="$REPO_ROOT/.claude/worktrees/bench-baseline-$BASELINE_SHA"
RESULTS="$REPO_ROOT/.claude/bench-results/$(date +%Y%m%d-%H%M%S)-$BASELINE_SHA-vs-$HEAD_SHA"
mkdir -p "$RESULTS"

echo "baseline : $BASELINE_SHA  ($(git log -1 --format=%s "$BASELINE_SHA"))"
echo "head     : $HEAD_SHA  ($(git log -1 --format=%s HEAD))"
echo "grid     : ${COLS}x${ROWS} cells"
echo "rounds   : $ROUNDS interleaved, device $DEVICE"
echo "results  : $RESULTS"
echo

# --- baseline worktree ------------------------------------------------------

if [ ! -d "$WORKTREE" ]; then
  echo "==> creating baseline worktree at $WORKTREE"
  git worktree add --detach "$WORKTREE" "$BASELINE_SHA"
fi

echo "==> installing the current harness into the baseline worktree"
mkdir -p "$WORKTREE/example/lib/bench"
cp "$REPO_ROOT/example/lib/benchmark.dart" "$WORKTREE/example/lib/benchmark.dart"
# The stub, not the real one: this commit has no TerminalRenderStats to read.
cp "$REPO_ROOT/example/lib/bench/bench_stats_stub.dart" \
   "$WORKTREE/example/lib/bench/bench_stats.dart"
# The window has to be the same size on both sides, or the larger grids are
# reachable on one build and not the other.
if [ "$DEVICE" = "macos" ]; then
  cp "$REPO_ROOT/example/macos/Runner/MainFlutterWindow.swift" \
     "$WORKTREE/example/macos/Runner/MainFlutterWindow.swift"
fi

# --- one run ----------------------------------------------------------------

run_bench() {
  local label="$1" dir="$2" out="$3"

  echo "    $label -> $(basename "$out")"
  (
    cd "$dir/example"
    flutter run \
      --profile \
      -d "$DEVICE" \
      -t lib/benchmark.dart \
      --dart-define=BENCH_LABEL="$label" \
      --dart-define=BENCH_COLS="$COLS" \
      --dart-define=BENCH_ROWS="$ROWS" \
      --dart-define=BENCH_EXIT=true
  ) >"$out" 2>&1 || {
    echo "    RUN FAILED - see $out" >&2
    return 1
  }

  if ! grep -q 'xterm2-bench.*flood:' "$out"; then
    echo "    RUN INCOMPLETE (no flood line) - see $out" >&2
    return 1
  fi
}

echo "==> flutter pub get"
(cd "$REPO_ROOT/example" && flutter pub get >/dev/null)
(cd "$WORKTREE/example" && flutter pub get >/dev/null)
echo

for round in $(seq 1 "$ROUNDS"); do
  echo "==> round $round/$ROUNDS"
  run_bench "baseline-$BASELINE_SHA" "$WORKTREE"  "$RESULTS/round$round-baseline.log"
  run_bench "head-$HEAD_SHA"         "$REPO_ROOT" "$RESULTS/round$round-head.log"
done

echo
echo "==> collected output"
for log in "$RESULTS"/*.log; do
  echo
  echo "--- $(basename "$log") ---"
  grep '\[xterm2-bench\]' "$log" | sed 's/^.*\[xterm2-bench\] //'
done

echo
echo "raw logs: $RESULTS"
echo "Before reading anything into a difference: the harness cannot resolve"
echo "less than about 0.5ms on p50. Check the grid line matches on both sides."
