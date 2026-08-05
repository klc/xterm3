# Benchmarks

Baseline numbers for the render pipeline, and the procedure that produced them.
Every phase of the work in `RENDER_PLAN.md` is accepted or rejected against this
table — a change that does not move a number here has not been shown to do
anything.

## Running

```sh
cd example
flutter run --profile -d macos -t lib/benchmark.dart
```

Profile mode is mandatory. Debug-mode frame times are dominated by assertions
and are not comparable to anything a user sees; the misleading DevTools charts
that started this investigation were debug-mode charts.

The harness lives in `example/lib/benchmark.dart`. It drives the terminal with a
precomputed, fixed byte stream — one write per frame, no PTY, no shell — so two
runs on the same machine do the same work. The viewport is pinned to
1000x600 logical pixels rather than filling the window, because cell count
drives every cost in the paint path.

Results print to the console prefixed with `[xterm2-bench]`.

## Workloads

| Name | What it exercises |
|---|---|
| `plain` | Scrolling ASCII. Small glyph set, every lookup a paragraph cache hit after warm-up. |
| `sgr` | Same glyphs, heavy SGR churn. Much larger cache key space. |
| `boxdraw` | Box drawing and block elements — the procedural glyph path, which never touches the paragraph cache. |
| `fullscreen` | Cursor-addressed full-screen redraw on the alternate screen. Every cell rewritten every frame. The deterministic stand-in for htop. |
| `static` | A full screen drawn once, then **one cell** changes per frame. The damage-tracking workload. |
| `flood` | `cat bigfile`: chunks handed to `Terminal.write` as fast as the event loop takes them. Measures whether output starves the frame pipeline, not the paint path. |

`static` is the one to watch. It is the case where the renderer does the most
work it did not need to do, so it is where partial repaint has to show up. If a
change improves `fullscreen` but leaves `static` where it is, it did not
implement damage tracking.

## Baseline — 2026-08-05

Commit `6172f9a`, before any render pipeline changes.
Apple M1 Pro, macOS 26.5.1, Flutter 3.44.2 stable, profile mode.
Terminal grid 100x37 (3700 cells) at 1000x600 logical px.
400 measured frames per workload after 60 warm-up frames.

Frame times in milliseconds:

| workload | frames | UI p50 | p90 | p99 | raster p50 | p90 | p99 | over 16.7ms |
|---|---|---|---|---|---|---|---|---|
| plain | 416 | 1.0 | 1.1 | 1.4 | 1.6 | 1.9 | 2.3 | 0.0% |
| sgr | 408 | 1.7 | 1.9 | 2.0 | 2.0 | 2.1 | 2.3 | 0.0% |
| boxdraw | 408 | 2.4 | 2.6 | 2.8 | 3.3 | 3.5 | 3.6 | 0.0% |
| fullscreen | 408 | 1.7 | 2.2 | 2.6 | 1.9 | 2.5 | 2.9 | 0.0% |
| static | 408 | 1.6 | 1.8 | 1.9 | 2.5 | 2.6 | 2.8 | 0.0% |

Paint path counters (`TerminalRenderStats`), reset after warm-up:

| workload | paints | lines/paint | paragraph hit% | lookups/frame | glyph hit% | lookups/frame |
|---|---|---|---|---|---|---|
| plain | 400 | 38.0 | 100.0% | 2110 | — | 0 |
| sgr | 400 | 39.0 | 100.0% | 2496 | — | 0 |
| boxdraw | 400 | 38.0 | — | 0 | 97.1% | 2220 |
| fullscreen | 400 | 37.0 | — | 0 | 100.0% | 1831 |
| static | 400 | 37.0 | 100.0% | 3514 | — | 0 |

Flood: 32.2 MiB in 467ms (70.6 MiB/s), 23 frames rendered during the burst
(49.2 fps), worst UI frame 3.4ms.

### What the baseline says

**Rendering is not close to the frame budget.** Worst p99 across every workload
is 2.8ms UI and 3.6ms raster against a 16.7ms budget — 0.0% of frames go over,
on every workload. This corroborates the earlier profile-mode observation that
render sits at roughly 15% of the frame budget. Nothing in the paint path is
currently costing users frames on this machine.

**The waste damage tracking would remove is real but small in absolute terms.**
`static` changes exactly one cell per frame, yet still visits 37 lines and does
3514 paragraph cache lookups every frame, all of them hits. Its UI p50 (1.6ms)
is indistinguishable from `fullscreen`'s (1.7ms), which rewrites all 3700 cells
— the renderer genuinely cannot tell the two apart. Damage tracking would take
most of that 1.6ms, but 1.6ms out of 16.7ms is headroom that is already there.

**`boxdraw` is the most expensive workload, not `fullscreen`.** 2.4ms UI /
3.3ms raster, at a 97.1% glyph cache hit rate. The 2.9% miss rate is doing real
work: procedural glyphs rebuild vector paths on a miss. Raising that hit rate
is a cheaper, more targeted win than any of the phases in `RENDER_PLAN.md`.

**The flood number is the one that looks wrong.** 49.2 fps during a write burst
means output starves the frame pipeline — that is the unbounded parse-per-write
path, not the paint path. No amount of render work fixes it.

Taken together: the render pipeline plan targets a bottleneck the measurements
do not show. Phase 4 of `RENDER_PLAN.md` — "measure, then decide" — can be
answered now rather than after building phases 1 through 3.

## Phase 1 — revision counters — 2026-08-05 — **not merged**

`BufferLine.revision` and `Buffer.viewportRevision` add an integer increment to
every cell write and every structural change to the line array. Same machine
and settings as the baseline above.

Kept on the `render-line-picture-cache` branch rather than merged: phase 3 was
its only consumer, and on master it would be a counter nobody reads, bumped on
hot paths like `setAsciiCells`.

| workload | UI p50 | p90 | p99 | raster p50 | p90 | p99 |
|---|---|---|---|---|---|---|
| plain | 0.9 | 0.9 | 1.0 | 1.4 | 1.5 | 1.7 |
| sgr | 1.5 | 1.7 | 1.9 | 1.8 | 2.1 | 2.2 |
| boxdraw | 2.3 | 2.4 | 2.6 | 3.2 | 3.4 | 3.5 |
| fullscreen | 2.0 | 2.3 | 2.5 | 2.2 | 2.6 | 2.8 |
| static | 1.6 | 1.8 | 1.9 | 2.6 | 2.8 | 2.9 |

Flood: 32.2 MiB in 439ms (75.2 MiB/s), 21 frames during the burst (47.9 fps).

Cache counters are identical to the baseline in every column, which is the
expected result: the counters observe mutations, they do not change them.

**No measurable cost.** Four of the five workloads came out *faster* than the
baseline, which adding work cannot do, so the increments sit under the noise.
See the run-to-run spread below before reading anything into a small delta.

## Phase 2 — paint pass split — 2026-08-05 — merged

`_paint` split into four passes plus a per-frame `_CursorPaintState`. Draw
calls are unchanged by construction and the golden tests confirm it, so any
movement here is either the extra call overhead or noise. Two runs, same
machine and settings.

| workload | UI p50 (run 1 / run 2) | raster p50 (run 1 / run 2) |
|---|---|---|
| plain | 1.3 / 1.0 | 2.1 / 1.7 |
| sgr | 1.6 / 1.7 | 2.2 / 2.4 |
| boxdraw | 2.3 / 2.3 | 3.3 / 3.3 |
| fullscreen | 2.1 / 2.2 | 2.3 / 2.3 |
| static | 1.6 / 1.7 | 2.6 / 2.7 |

Cache counters identical to both earlier tables.

These runs had phase 1's counters compiled in, since phase 2 was built on top
of phase 1. What master actually ships is phase 0 + phase 2 without them, and
that combination has not been measured on its own. Phase 1 measured as free, so
the difference should be nothing, but nobody has checked.

### Run-to-run spread, measured

Across the four runs now on record (baseline, phase 1, phase 2 ×2), `plain`
UI p50 came in at 1.0, 0.9, 1.3 and 1.0 — a 0.4ms spread with no code change
that could explain it, and its raster p50 spread 1.4 to 2.1. **Treat ±0.5ms on
p50 as noise, and more than that on p99.** An earlier note in this file put the
band at ±0.3ms; that was too tight.

This means the harness cannot currently resolve a change smaller than roughly
half a millisecond. Anything claiming a win under that needs repeated runs,
interleaved A/B rather than sequential, on an otherwise idle machine.

### One thing to watch

`fullscreen` UI p50 has gone 1.7 → 2.0 → 2.1 → 2.2 across the four runs in
order. That is a monotonic climb rather than a scatter, which noise does not
usually produce. It is also consistent with the machine warming up over an
afternoon of runs, and the runs were sequential rather than interleaved, so the
two cannot be separated from this data. Re-measure `fullscreen` from a cold
machine with the phase 1 and phase 2 commits checked out alternately before
concluding anything.

## Phase 3 — line picture cache — 2026-08-05 — **not merged**

Per-line `ui.Picture` recordings replayed while `BufferLine.revision` holds
still. Lives on the `render-line-picture-cache` branch and stays there; the
numbers below are why. Two runs.

| workload | UI p50 (1 / 2) | raster p50 (1 / 2) | line hit% |
|---|---|---|---|
| plain | 0.6 / 0.6 | 2.3 / 2.2 | 89.5% |
| sgr | 0.3 / 0.4 | 2.6 / 2.7 | 100% (see below) |
| boxdraw | 1.2 / 1.1 | 3.5 / 3.4 | 89.5% |
| fullscreen | 2.4 / 2.4 | 2.1 / 2.1 | 0.0% |
| static | 0.4 / 0.4 | 3.4 / 3.5 | 97.3% |

The cache does what it was built to do. `static` goes from 3514 paragraph
lookups per frame to 95, and its UI p50 from 1.7ms to 0.4ms — a 76% cut, well
outside the noise band. `fullscreen` hits 0% exactly as predicted: every line
changes every frame, so there is nothing to replay.

### Why it is not merged

Raster time went up everywhere the UI time went down, and by enough to matter:

| workload | UI + raster (phase 2 → 3) | max(UI, raster) (phase 2 → 3) |
|---|---|---|
| plain | 2.7 → 2.8 | 1.7 → **2.2** |
| boxdraw | 5.6 → 4.5 | 3.3 → 3.4 |
| fullscreen | 4.5 → 4.5 | 2.3 → 2.4 |
| static | 4.4 → 3.9 | 2.7 → **3.5** |

UI and raster run on separate threads and are pipelined across frames, so
sustained frame rate is bounded by the slower of the two, not their sum. Raster
was already the slower thread on every cache-friendly workload, and this change
makes it slower still — roughly 0.55ms of raster bought per 1ms of UI saved.
By that measure `static` gets **worse**, 2.7ms to 3.5ms, and `plain` worse by
0.5ms; both deltas repeat across the two runs, so neither is noise.

Read as single-frame latency (UI + raster) instead, `static` improves slightly,
4.4ms to 3.9ms. Both readings are defensible, and neither is actionable,
because no workload is anywhere near the 16.7ms budget in either model.

The cause is the one the plan predicted: 37 lines × 2 recordings is 74
`drawPicture` calls per frame, and Skia batches across a single command stream
better than across many small pictures.

The plan's own acceptance criterion for this phase was "if raster goes up and
build goes down, there is no net win — revert phase 3." That is what the
measurements say, so the branch stays unmerged.

### The `sgr` row is not trustworthy in any phase

`sgr` reports 100% line hits and zero paragraph lookups, meaning no foreground
was recorded across 400 frames — impossible for a workload writing three fresh
lines per frame. The cache is not the culprit:
`test/src/ui/line_picture_cache_test.dart` covers re-recording on revision
change, on a new line object and after a cache clear, and a standalone replay
of `sgr`'s exact byte stream through the cached painter behaves identically to
`plain` (433 misses and 21312 paragraph lookups over 100 frames).

The likely explanation is that `sgr`'s viewport is not following the scroll in
the benchmark, so the visible lines genuinely never change. That would have
been just as true in phases 0-2, where a frozen viewport still costs full-price
lookups every frame and so looked normal. Until that is confirmed, treat the
`sgr` row as measuring an unknown, in every table in this file.

## Adding a workload

Workloads are lists of per-frame strings built by a `_*Frames` function and
registered in `_run()`. Pass `setup:` for screen content that should be written
once before measurement rather than counted as per-frame work, and
`enterAltScreen: true` for anything that should not touch scrollback. Keep
generators deterministic — no clocks, no randomness without a fixed seed —
or the numbers stop being comparable between runs.
