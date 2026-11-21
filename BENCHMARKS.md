# Benchmarks

Baseline numbers for the render pipeline, and the procedure that produced them.
Every phase of the render plan was accepted or rejected against this table — a
change that does not move a number here has not been shown to do anything. The
plan itself, which the phase numbers below refer to, is retired and kept in
history: `git show 50f0211:RENDER_PLAN.md`.

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
runs on the same machine do the same work.

The grid is pinned to **100x37 cells**, not to a pixel size. Cell count drives
every cost in the paint path, and cell metrics are not stable across builds:
`fix(ui): size cells from a reference glyph, not the widest ASCII glyph` moved
them, so the 1000x600 viewport the first tables in this file were taken at
yields 100 columns on today's build and 102 on the published one. The harness
therefore bisects the viewport extent at startup until the terminal reports
exactly 100x37 and aborts the run if it cannot, rather than reporting numbers
from two different grids as if they were comparable.

Results print to the console prefixed with `[xterm3-bench]`.

To compare this working tree against an older commit:

```sh
script/bench-compare.sh [baseline-ref] [rounds]   # default 8d938de, 3 rounds
```

It puts the baseline in a git worktree, copies *this* tree's harness over it so
both sides run identical measurement code, and alternates the two builds. Runs
must be interleaved: sequential ones drift (see the `fullscreen` note below).
`example/lib/bench/bench_stats.dart` is the one harness file that differs
between the sides — the baseline gets `bench_stats_stub.dart`, because
`TerminalRenderStats` does not exist there. Frame timings come from
`SchedulerBinding` and are unaffected.

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
is a cheaper, more targeted win than any of the render plan's phases.

**The flood number is the one that looks wrong.** 49.2 fps during a write burst
means output starves the frame pipeline — that is the unbounded parse-per-write
path, not the paint path. No amount of render work fixes it.

Taken together: the render pipeline plan targets a bottleneck the measurements
do not show. Phase 4 of the render plan — "measure, then decide" — can be
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

## Against the published package — 2026-08-05

`8d938de` (head of `klc/xterm3` master, 2026-07-28) versus `d6f7b59`,
73 commits later. Apple M1 Pro, macOS 26.5.1, Flutter 3.44.2 stable, profile
mode, three interleaved rounds per build via `script/bench-compare.sh`.

Both builds measured a 100x37 grid — which is the only reason the table means
anything. At a fixed 1000x600 viewport the published build lays out **102**
columns to this build's 100, because cell width changed from 7.86px to 8.00px.
Comparing those two runs directly would have credited this build with a 2%
smaller grid.

Median of three rounds, milliseconds. Within-build spread was at most 0.2ms on
every cell below, so unlike the phase tables in this file, differences of 0.3ms
are outside the noise here.

| workload | UI p50 pub → now | raster p50 pub → now |
|---|---|---|
| plain | 1.3 → **0.8** | 1.5 → **1.3** |
| sgr | 2.2 → **1.4** | 1.8 → 1.6 |
| boxdraw | 2.1 → 2.2 | 2.7 → **3.0** |
| fullscreen | 1.2 → 1.4 | 1.4 → 1.6 |
| static | 2.4 → **1.5** | 2.4 → 2.1 |

Flood, MiB/s across the three rounds: 72.9 / 66.8 / 67.5 published,
74.6 / 71.8 / 75.1 now. Every pairwise round favours the newer build, by around
7%. Nothing in these 73 commits touched the parse loop, so read this as the
write path being marginally less obstructed, not as the unbounded-parse-per-
write problem having moved. It has not.

### What moved

**The cached text path got a third faster.** `plain` UI p50 1.3 → 0.8, `sgr`
2.2 → 1.4, `static` 2.4 → 1.5. The three commits that can account for it are
`21c8773` (no defensive listener copy per `Terminal.write`), `53ae0e3` (O(1)
paragraph cache eviction) and `c3051b7` (cached procedural glyph rasters). All
three are on the per-frame path these workloads sit in.

**The procedural glyph path got slower to rasterise.** `boxdraw` raster
2.7 → 3.0, `fullscreen` raster 1.4 → 1.6, and both are repeatable across all
three rounds with no overlap between the builds. This is the opposite of what
`c3051b7` was supposed to do, and it is the one result here worth chasing:
replaying a cached `ui.Picture` per glyph appears to cost the raster thread
more than re-tesselating the path cost it, even at a 97.1% hit rate. Note that
`3e9266c` also changed how heavily box-drawing bars are stroked, so some of the
extra raster work is extra pixels rather than extra draw calls — the two have
not been separated.

Neither direction matters to a user yet: the worst number in the table is
3.0ms against a 16.7ms budget, and no workload put a single frame over budget
on either build.

### At a full-screen grid, where the differences are visible

3700 cells is a small window. Re-run at **170x50 (8500 cells)**, the size a
maximised terminal actually is, and the same commits look different — every
paint-path cost scales with cell count, so both the wins and the regression
scale with it. Same three-interleaved-rounds procedure, medians, and the
within-build spread stayed at 0.1-0.2ms.

| workload | UI p50 pub → now | raster p50 pub → now |
|---|---|---|
| plain | 2.1 → **1.6** | 2.4 → 2.6 |
| sgr | 3.0 → **1.9** | 2.4 → 2.6 |
| boxdraw | 2.9 → **2.6** | 3.6 → 3.9 |
| fullscreen | 3.0 → 3.0 | 3.2 → 3.2 |
| static | 5.1 → **2.7** | 8.6 → **4.5** |

`static` is the headline: raster p50 halves, 8.6ms to 4.5ms, and UI drops 47%.
At 3700 cells the same commits moved it by under a millisecond and it read as
noise-adjacent; at 8500 it is a quarter of the frame budget on the raster
thread. Flood is unchanged at about 55 MiB/s on both builds — the grid is
bigger, so more of each burst goes into painting, and nothing here touched the
parse loop anyway.

The remaining `boxdraw` raster gap is **not** a regression. It survives with
the glyph cache compiled out entirely, and it is explained by cell size: the
same 170 columns come out 1366.8px wide on this build against 1330.9px on the
published one, so 2.7% more pixels are rasterised per frame. 3.6 x 1.027 = 3.7.

### The glyph cache defect this run found

The first 170x50 run had `boxdraw` UI p50 at **4.6ms** against the published
build's 2.9ms, and `fullscreen` raster at 3.6ms against 3.2ms. Both were
`c3051b7`, the procedural glyph cache, and both are fixed above. Two separate
faults:

**The cache was too small to hold one screen, and a miss cost more than not
caching.** Keys are (codepoint, cell size, colour), so `boxdraw`'s 15 glyphs
across 256 colours reach 3840 live keys against a 512-entry cache. The hit rate
fell from 97.1% at 3700 cells to **75.0%** at 8500, and because a miss pays for
the recording and the insert *on top of* the drawing, the cache made the build
1.9ms per frame slower than painting uncached. Capacity is now 4096. Measured
at 8192 for comparison: 99.9% hit, and no further gain over 4096's key space.

**Block elements should never have been cached.** `U+2580..U+259F` are one or
two `drawRect` calls. Recording that into a `Picture` and replaying it per cell
puts a picture boundary in the raster command stream for every cell, and Skia
batches worse across many small pictures than across one stream — the same
effect that sank phase 3 above. On `fullscreen`, which is entirely `U+2588` at
a 100% hit rate, the cache cost 0.4ms of raster per frame and saved nothing on
the UI thread. They now bypass the cache, and `fullscreen` is back to parity
with the published build on both threads.

The general lesson, and it is the second time this file records it: **a cache
that hands the raster thread more, smaller pictures is not free, and has to be
measured on the raster thread, not just on the UI thread.**

### Correctness, which is where most of the 73 commits went

Running this build's test suite against the published library:

| | published `8d938de` | now `d6f7b59` |
|---|---|---|
| tests run | 391 | 809 |
| failures | 20 | 0 |

Five of those 20 are whole files that do not compile against the published
library — `painter_test`, `render_test`, `render_stats_test`,
`android_ime_input_test` and `terminal_test` — so the tests inside them never
ran, and 391 is an undercount rather than a comparable total. The 15 that ran
and failed are the regressions the commits since then fixed: wide-char
lead/placeholder corruption (five, from the fuzz harness), Kitty keyboard
release and modifier reporting (three), mobile IME double-insertion and
backspace-at-zero (two), `TerminalView.textScaler` (two), default pointer
input reporting, box-drawing stroke weight, and a colour golden.

## The write path — 2026-08-06

`flood` says output starves the frame pipeline, but it cannot say which part of
the write path is paying, because it measures the parser, the buffer writes it
drives and the repaints it schedules all at once. `bin/parse_bench.dart` splits
them, with no Flutter and no renderer:

```sh
dart compile exe bin/parse_bench.dart -o /tmp/parse_bench && /tmp/parse_bench
```

Compile it — JIT numbers are not comparable to what ships. 32 MiB per workload
in 8 KiB chunks, 170x50 grid, Apple M1 Pro.

| workload | full | parser | buffer% | no scrollback | no graphemes |
|---|---|---|---|---|---|
| ascii | 108 | 439 | 75% | 143 | 108 |
| ascii-long-lines | 125 | 699 | 82% | 174 | 126 |
| sgr | 55 | 100 | 45% | 67 | 56 |
| utf8 | 60 | 260 | 77% | 70 | 82 |
| cyrillic | 87 | 286 | 70% | 116 | 88 |
| altscreen | 136 | 226 | 40% | 138 | 138 |

MiB/s. `full` is `Terminal.write`; `parser` is the same bytes through
`EscapeParser` with a handler that does nothing; the other two columns turn off
scrollback and DEC mode 2027 respectively.

Medians of three interleaved rounds, taken on `master` after phase 6.1. The
absolute values are lower across the board than the tables further down this
file, which were taken on a faster day on the same machine — day-to-day drift
on this hardware runs to about 20%, so read a row against its own table and
never across two of them.

**The parser is not the bottleneck, except on `sgr`.** Plain text parses at
439 MiB/s and the full path manages 108, so 75% of the time is what the
terminal does per token. `sgr` is the exception: 100 MiB/s through the parser
alone means CSI dispatch itself is the ceiling there, and no amount of buffer
work will move it. Three attempts at the CSI parameter loop confirmed that from
the other side - see phases 5.4 and 5.5 of the render plan, and
`script/csi_param_census.dart` for why no fourth is worth writing.

**Scrolling still costs about a third.** `ascii` at 108 against 143 with
scrollback disabled, and `altscreen` — which never scrolls — runs at 136. A
line of output allocates a `BufferLine`, and its cell storage is a
`Uint32List`. Two things have been taken off that bill. Capacity rounding was
the cheap part: `_calcCapacity` doubled from 64, so a 170-column line reserved
256 cells and addressed 170; rounding to 32 instead took `ascii` from 92 to 103
MiB/s and long lines from 129 to 149. The larger part was the size of the store
itself, which phase 6.1 addressed by letting the first write size it instead of
allocating at viewport width — `ascii` +18%, `cyrillic` +19%, `utf8` +24%, at
the cost of 13% on `sgr`.

What is left of the gap is not work a faster path can skip. It is the garbage
collector holding the retained lines: phase 7 of the render plan measured that
`IndexAwareCircularBuffer.push` does *less* work at a depth of 10000 than at
50, and is slower anyway. Recycling the storage does not work either — see
below.

**Non-ASCII text used to run at a sixth of ASCII speed.** Both causes are
fixed below; the table above is after those fixes.

### Grapheme clustering no longer costs Latin text anything

`utf8` measured **15 MiB/s** before this section was written, against a
34 MiB/s ceiling with mode 2027 turned off — grapheme detection was more than
half the cost of writing Turkish, and by extension of every non-English
language written in Latin script.

`_joinsPreviousGrapheme` had a fast path for the case where the previous cell
and the incoming code point are both ASCII. One accented letter breaks it: with
`ö` in the previous cell, every following character fell through to real
grapheme segmentation, which allocates two strings and segments both of them.
Nothing below U+0300 can continue a grapheme cluster — the first combining
marks live there, and everything else that can extend a cluster (SpacingMark,
ZWJ, regional indicators, emoji modifiers, Hangul V and T) sits higher — so the
cut is now made on the code point, and Latin text never reaches the segmenter.
The same cut lets `writeChar` skip both cluster checks outright.

15 → 32 MiB/s, against a 35 MiB/s ceiling. What was left is the per-code-point
path, dealt with next.

### Batched writes for alphabets other than English

The parser batches a run of printable ASCII into one `writeText` call and hands
everything else to `writeChar`, one code point at a time. So the first accented
letter ended the run, and every letter after it started a run of its own — an
alphabet that is *entirely* non-ASCII never batched at all. Cyrillic measured
**6 MiB/s**, a fifteenth of ASCII.

`isSingleCellPrintable` now defines the run: ASCII, Latin-1, Latin Extended-A
and B, IPA, spacing modifiers, Greek, Cyrillic and Armenian, minus the two
combining blocks inside that span and U+00AD. Every code point in it is width 1
and cannot continue a grapheme cluster, which is exactly what a batched write
needs in order to skip the width table and the cluster rules. The same
predicate replaces the U+0300 cut in `writeChar`, so a single such character
outside a run is just as cheap.

Cyrillic 6 → 73 MiB/s. Turkish 32 → 54, where the rest of the gap to ASCII is
the em dashes and other punctuation the ranges leave out. CJK is deliberately
not in this set: it is width 2 and needs the path that allocates a lead cell
and a placeholder.

### Pacing the write path — measured, offered as opt-in

`flood` writes chunks as fast as the event loop takes them, which is what a PTY
stream listener does. At 170x50 that drains 32 MiB in 566ms and produces 37
frames per second while it does — the burst spends about 89% of its time
parsing and 11% painting, so frames happen in whatever gaps parsing leaves.

The harness now also measures a paced variant: parse until a budget is spent,
hand the thread back, repeat.

| mode | drain | throughput | frames | worst UI frame |
|---|---|---|---|---|
| unpaced | 566ms | 58.3 MiB/s | 37.1 fps | 3.2ms |
| paced, 8ms budget | 854ms | 38.6 MiB/s | **74.9 fps** | 1.9ms |
| paced, 4ms budget | 1068ms | 30.9 MiB/s | 74.9 fps | 1.4ms |

Pacing doubles the frame rate to the display's full refresh rate, and costs
about 50% in drain time. 4ms buys no more frames than 8ms and only drains more
slowly, so 8ms is the default in `PacedTerminalWriter`, which is the opt-in
this measurement produced. Nothing in the package uses it by default: which
side of that trade an application wants is not the package's call.

Note what this is not: the unpaced case was never freezing. Its worst UI frame
during the burst is 3.2ms. The frame rate is low because parsing owns the
thread between frames, not because any single frame is slow. That holds for
`flood`, which has no PTY. Through a real PTY the app draws a handful of frames
in a whole burst: see *Frame starvation through a PTY — 2026-11-20*.

### Recycling evicted lines — measured, rejected

The obvious answer to the scrolling cost is to blank the line that just fell
off the scrollback and push it back on, instead of allocating a replacement.
Implemented as `BufferLine.reset` plus a bounded pool in `Buffer`, it made
`ascii` **worse**: 92 → 41 MiB/s zeroing the whole capacity, 92 → 52 zeroing
only the live cells. The VM's allocator hands out typed data that is already
zeroed, and clearing 3 KiB by hand costs more than asking for a fresh one.

Anything else aimed at the scrolling cost has to reduce the *number* of lines
allocated or their size, or find a way to reuse one without clearing all of it.

Two things this experiment settled without a further run. First, its own
numbers answer how much of the scrollback penalty is allocation: pooling
without the clear recovers 63% of it on `ascii`, 84% on `cyrillic` and 93% on
`utf8`. Nearly all of it. Second, the explanation offered above — that the VM
hands out typed data the OS already zeroed — needed checking before a second
attempt, because whether clearing only the written span can pay depends on it.
It was checked, and it holds: see "Recycling evicted lines, take two" below.

## Where it stands against the published package — 2026-08-06

Everything above, re-measured against `8d938de` after the render and write-path
work was done. Render: three interleaved rounds at 170x50, medians, spread
0.1-0.2ms within a build. Write path: `bin/parse_bench.dart` compiled against
each build, 32 MiB per workload.

### Frame times, milliseconds

| workload | UI p50 pub → now | raster p50 pub → now |
|---|---|---|
| plain | 2.1 → **1.6** | 2.3 → 2.5 |
| sgr | 3.0 → **1.8** | 2.4 → 2.5 |
| boxdraw | 2.8 → **2.5** | 3.5 → 3.9 |
| fullscreen | 3.0 → 3.0 | 3.1 → 3.1 |
| static | 5.1 → **2.7** | 8.7 → **4.5** |

### Write path, MiB/s

| workload | pub | now |
|---|---|---|
| ascii | 93 | **103** |
| ascii-long-lines | 131 | **146** |
| sgr | 74 | 76 |
| utf8 (Turkish) | 16 | **57** |
| cyrillic | 6 | **84** |
| altscreen | 172 | 169 |

### Draining 32 MiB into a 170x50 grid

| | pub | now |
|---|---|---|
| unpaced | 596ms, 32 fps, worst UI 4.9ms | **532ms, 41 fps**, worst UI 4.0ms |
| paced 8ms | 855ms, 75 fps, worst UI 4.2ms | **761ms**, 75 fps, worst UI **1.9ms** |
| paced 4ms | 1563ms, 75 fps | **1068ms**, 75 fps |

Unpaced is both faster to drain and smoother than the published build, which is
the write-path work showing up. Paced is available on both builds — the harness
provides the pacing — and the published build pays for its slower parser there
too, taking 12% longer at an 8ms budget and 46% longer at 4ms.

### What has not moved

`sgr` is unchanged in every table: 74 → 76 MiB/s on the write path, and the
parser alone caps it at 99 — see "The `parser` column was wrong until
2026-08-29" below, which re-measures that cap at 121 and cuts the parser's
share of `sgr` from 77% to 64%. Nothing here touched CSI dispatch either way. `altscreen` is unchanged because it neither scrolls nor allocates
lines. `fullscreen` frame times are at parity by design — the glyph cache
regression that had moved them was removed rather than tuned.

The `boxdraw` raster gap is not a regression: it survives with the glyph cache
compiled out, and 170 columns are 1366.8px wide on this build against 1330.8px
on the published one, so 2.7% more pixels are rasterised per frame.

## The `parser` column was wrong until 2026-08-29

Every `parser` number above this line, and every `buffer%` derived from one, was
measured with a no-op handler that implemented `writeChar` and `writeText` and
let the other 233 `EscapeHandler` members fall through to `noSuchMethod`. Each
of those calls allocated an `Invocation` and boxed its arguments, so the column
charged the parser for work the real `Terminal` never does.

The comment justifying it said escape sequences are rare per byte. The workload
generators in the same file disagree: `ascii` reaches a handler about 22,000
times per MiB through `\r\n` alone, and `sgr` about 50,000 times.

`bin/noop_escape_handler.dart` now implements every member explicitly, with no
`noSuchMethod`, generated from the declarations by `script/gen_noop_handler.dart`.
Leaving `noSuchMethod` out is the point: `implements` without it turns a member
the benchmark has not caught up with into an analyzer error rather than a
quietly poisoned number.

### Old and new, medians of three runs each

| workload | full | parser | buffer% | scrollback | no-grapheme |
|---|---|---|---|---|---|
| ascii | 107 → 105 | 437 → **568** | 76 → **82** | 173 → 171 | 105 → 107 |
| ascii-long-lines | 149 → 151 | 824 → **910** | 82 → **84** | 230 → 227 | 148 → 149 |
| sgr | 76 → 77 | 99 → **121** | 23 → **36** | 86 → 88 | 75 → 77 |
| utf8 | 58 → 59 | 267 → **333** | 78 → **82** | 86 → 86 | 70 → 69 |
| cyrillic | 85 → 85 | 294 → **360** | 71 → **76** | 140 → 139 | 83 → 86 |
| altscreen | 172 → 170 | 232 → **279** | 26 → **39** | 174 → 175 | 174 → 175 |

`full`, `scrollback` and `no-grapheme` all run against the real `Terminal` and
never touched `noSuchMethod`. They are unmoved across three runs each, which is
the control the change had to pass: only the intended column moved.

Backing the artifact out of the column difference gives 22-24 ns per
zero-argument handler call and 37-44 ns per call carrying arguments — consistent
with an `Invocation` allocation plus argument boxing, and the reason the
artifact weighed on `sgr` about 2.3x what it weighed on `ascii`.

### What this changes

The buffer's share of the write path is **larger** than the earlier tables said,
not smaller: 82-84% on plain text, and 36-39% even on the two escape-heavy
workloads. `sgr` is still the most parser-bound workload and its parser column
is still by far the slowest at 121 MiB/s, but the "SGR is 77% parser" reading
was really 64%.

What did not change: `sgr`'s full-path throughput, and the cost of retaining
scrollback. Both come from columns the defect never touched.

## Taking the surrogate decode off `consume()` — 2026-08-29

`ByteConsumer.consume()` called `_decodeCodePoint` and `_codePointCodeUnitLength`
per code point, and both re-ran the same high-surrogate test to reach the same
answer. Testing once and returning early covers everything outside astral text.

Measured as an interleaved A/B — three rounds of each binary, alternating, so
thermal drift lands on both conditions. A first attempt that ran the two
conditions back to back was thrown away: columns that never touch `consume()`
moved 4-8% with it, which is drift, not signal.

| workload | full | parser | scrollback | no-grapheme |
|---|---|---|---|---|
| ascii | 105 → 106 | 567 → 579 | 166 → 172 | 106 → 103 |
| ascii-long-lines | 152 → 152 | 916 → 922 | 225 → 226 | 148 → 149 |
| sgr | 76 → **81** | 121 → **133** | 85 → 88 | 76 → **80** |
| utf8 | 58 → 59 | 334 → 342 | 86 → 86 | 69 → 69 |
| cyrillic | 85 → 85 | 348 → 364 | 140 → 138 | 85 → 85 |
| altscreen | 171 → **178** | 276 → **296** | 174 → **182** | 175 → **182** |

The gain is concentrated on the two escape-heavy workloads, which is where
`consume()` is hot. Plain text goes through `printableTextRunLength` and
`consumeAsciiCodeUnits` instead and barely reaches it. Nothing regressed in any
of the 24 cells, and the two conditions do not overlap on `sgr` (76/76/77
against 80/81/82) or `altscreen`'s parser column (272/276/279 against
296/296/300).

### The baseline after this

| workload | full | parser | buffer% | scrollback | no-grapheme |
|---|---|---|---|---|---|
| ascii | 106 | 579 | 82% | 172 | 103 |
| ascii-long-lines | 152 | 922 | 84% | 226 | 149 |
| sgr | 81 | 133 | 39% | 88 | 80 |
| utf8 | 59 | 342 | 82% | 86 | 69 |
| cyrillic | 85 | 364 | 77% | 138 | 85 |
| altscreen | 178 | 296 | 40% | 182 | 182 |

This also prescreened CSI bulk scanning, which was the point of doing it first:
`consume()` was carrying real cost, so that candidate survives. Its ceiling
narrowed though - the same derivation now puts CSI at **at most** ~17 ns per
character, down from ~19, and that bound still contains the CSI handler's own
parameter walk and dispatch rather than `consume()` alone.

## Recycling evicted lines, take two — measured, rejected again — 2026-08-29

The first attempt cleared the whole capacity with `fillRange` and lost. The
obvious repair was to clear only what the line had actually written. Measured
with `script/line_reuse_probe.dart` before building anything, because the
repair only makes sense if allocation's zeroing is genuinely free.

A `BufferLine` at 170 columns is `Uint32List(192 * 4)` — 3072 bytes, not the
680 an earlier note claimed. Per line, on an M-series macOS:

| | ns per line | ns per word |
|---|---|---|
| allocate | 92 | **0.12** |
| indexed store loop | — | **0.475** |
| `fillRange` | — | **1.6** |

Allocating is four times cheaper per word than the cheapest thing that actually
writes those words, so allocation is not writing them. The explanation offered
for the first attempt was right.

The consequence, with `written` as the cells a line holds text in out of a
192-cell capacity, and `loop-tail` clearing only the span between the new write
extent and the previous high-water mark — the best form of the design:

| written | alloc | fill-all | fill-written | loop-written | loop-tail |
|---|---|---|---|---|---|
| 30 | 153 | 1287 | 251 | 161 | 197 |
| 60 | **199** | 1323 | 492 | 307 | 242 |
| 120 | **304** | 1445 | 988 | 611 | 340 |
| 192 | 450 | 1565 | 1565 | 1023 | **355** |

Pooling wins only at full width, and only because there is nothing left to
clear there — what it wins is exactly the 92 ns of allocation. Across the
middle widths, where shell output sits, it loses. The prediction that a bounded
clear "pays on typical short shell lines" came out backwards: a short line
leaves a *long* tail to clear, because the line under it was wider. Pool depth
does not matter — 8, 64 and 512 give the same table.

So the closing line of the first attempt stands unchanged: anything aimed at
the scrolling cost has to reduce the *number* of lines allocated or their size,
not try to reuse them.

One finding with no use here: `fillRange` costs 3.4x an indexed store loop, so
it does not lower to a memset. `BufferLine.eraseRange` already clears cell by
cell, and the only other `fillRange` calls in `lib/` are one-time table setup —
recorded so nobody puts one on a hot path later.

## CSI parameter bulk scanning — measured, rejected — 2026-08-29

The candidate the write-path briefing opened with: CSI parameters are ASCII
digits, so scanning a run of them should beat calling `ByteConsumer.consume()`
per digit the way the printable-text path already does. Two implementations,
both slower than what they replaced.

A free experiment first. The digit case sat seventh in `_consumeCsi`'s branch
chain, and digits are about two thirds of the parameter bytes; none of the six
tests before it can match 0x30-0x39, so hoisting it is semantically identical.
It measured **nothing** — `sgr` parser 133 → 132, `altscreen` 297 → 299, both
inside the noise. The branch chain is not what a CSI byte pays for.

| | sgr full | sgr parser | altscreen full | altscreen parser |
|---|---|---|---|---|
| baseline | 81 | 132 | 179 | 298 |
| run scanner + bulk advance | 74 | 115 | 166 | 267 |
| scan and accumulate fused | 77 | 121 | 170 | 278 |

The first version scanned the run in one getter and accumulated it in another
loop, which cost four separate `_advancePastConsumedBlocks()` calls per run and
read every digit twice. Fusing the two loops recovered about half of the loss
and still landed 8% below the baseline, with the two conditions disjoint across
three interleaved rounds.

The reason is that the fast path merged earlier the same day left nothing to
batch. `consume()` is now one normalisation compare, one block read, one
`codeUnitAt` and four field updates. The bulk path replaces `run` of those with
an emptiness check, two getters that each normalise again, a limit computation,
a scan loop, and a `consumeAsciiCodeUnits` that normalises a third time. In
`sgr` a sequence averages 9.6 bytes and its parameters are one to three digits;
with the first digit already consumed, the bulk path is left with about 1.5
digits to amortise all of that over. It cannot.

Worth keeping from the attempt: the fuzzer earns its place. The fused version
initially called `currentBlock` unguarded, which throws `StateError` when the
digit just consumed was the last byte of the chunk.
`test/src/core/escape/parser_fuzz_test.dart` caught it on three separate seeds.
Anything reaching into the queue after `consume()` inside the CSI loop has to
assume the queue may now be empty.

## Where the scrollback cost actually is — 2026-08-29

The `scrollback` column runs with `maxLines: 0`, which `Buffer` widens to
`max(maxLines, viewHeight)`. The ring is still 50 lines, the allocation per
scroll is the same and so is the eviction bookkeeping — the only thing that
changes is how many lines stay alive. On `ascii` that column is worth 328 ns
per line and `line_reuse_probe` put allocation on its own at 92 ns, so
`script/scrollback_cost_probe.dart` went looking for the other 236.

It is the live set. A line writing 30 cells costs 151 ns with 50 alive and
**561 ns with 10000 alive** — the collector promoting each line's 3072-byte
backing store into old space, at a copy proportional to the store rather than
to the text in it.

| depth | live | w=30 | w=60 | w=120 | w=192 |
|---|---|---|---|---|---|
| 50 | 0 MB | 151 | 174 | 274 | 388 |
| 1000 | 3 MB | 169 | 203 | 307 | 424 |
| 4000 | 12 MB | 285 | 326 | 415 | 533 |
| 10000 | 29 MB | 561 | 629 | 767 | 814 |

So the lever is line size, which is the half of Phase 5's closing line nobody
had tried. Allocating each line at `_calcCapacity` of the width it actually
writes, at 10000 deep: 561 → 180 at 30 cells, 629 → 345 at 60, 767 → 590 at
120. It would also take scrollback's resident cost from 30 MB down to roughly
10-15 MB on a realistic mix.

### Trimming on the way into scrollback does not work

The obvious form, and the one with the narrow blast radius: keep the line at
full capacity while it is in the viewport, give it a right-sized store when it
drops into scrollback. Nothing in the write path changes, the painter already
drives off `line.length`, `getText` skips zero code points so its output is
unchanged, and `Buffer.resize` already grows lines back on a window change.

`script/trim_variant_probe.dart` says no, in every cell measured:

| depth | written | today | trim | born small |
|---|---|---|---|---|
| 1000 | 30 | 171 | 224 | 79 |
| 1000 | 95 | 248 | 336 | 186 |
| 10000 | 30 | 544 | 601 | 181 |
| 10000 | 95 | 646 | 819 | 394 |
| 10000 | 120 | 691 | 970 | 581 |

Trimming spends an allocation and a copy of the small store to save promoting
the large one, and the two are the same order of magnitude. The saving is in
never allocating the large store, not in handing it back. Recorded because this
is the form of the idea that looks best on paper.

Not implemented: a line born at the 64-cell floor and grown from inside
`BufferLine`'s own write methods. Ceiling measured at 1.2-3.0x, cost on the
per-code-point write path unmeasured.

## Costs of a code review's findings — 2026-08-29

A review flagged thirteen things by inspection. Nine held up against the code;
`bin/review_bench.dart` then measured the ones that are measurable, because
inspection cannot tell a finding that costs a microsecond a minute from one
that costs a millisecond a frame. Numbers are medians of five, interleaved
before and after.

| finding | before | after |
|---|---|---|
| `wholeWord` search, matches abutting word chars | 14.3 ms | **12.9 ms** |
| `wholeWord` search, matches at word boundaries | 7.2 ms (+10% over plain) | **6.6 ms (+1%)** |
| `urlAt` per pointer hover | 1.3-1.9 us + ~3 KB | **not run while the modifier is up** |
| editable rect reports per 50 writes | 50 ancestor walks | **1, at the next paint** |
| `runes.length` + `runes.first` per keystroke | 25 ns | **3 ns** |
| `isSemanticPromptLine`, 1000 prompts queued | 14.5 us | 19.4 us |
| reflow 10000 lines, one anchor each | 199-214 ns/line | 204-249 ns/line |
| OSC 52 clipboard, 8 KiB payload | 12.6 ns/byte | 12.7 ns/byte |

The last three are the honest part of the table.

**Reflow anchors and the OSC rejoin measured neutral.** `BufferLine.anchors`
really does allocate an `UnmodifiableListView` per call and reflow really did
call it inside its copy loop, and `_osc.sublist(n).join(';')` really does
allocate a list to copy strings that mostly did not need copying. Both are now
avoided, and neither shows up in the timing. They are kept because they remove
provably dead work and because `hasAnchors` is the API the code wanted, not
because they made anything faster - and this table is where that is written
down rather than implied.

**The semantic prompt queue got slower, deliberately.** The prune only dropped
stale anchors from the front, so anchors that went stale in the middle stayed.
That is not just wasted scanning: the queue is capped at the buffer's line
count and the cap evicts from the front, so enough stale entries push a
still-valid prompt out and the terminal forgets a prompt that is on screen.
`terminal_test.dart` has that as a regression test, and it fails against the
old prune. The full sweep costs one extra traversal of the queue - 5 us at
1000 queued prompts - on a path that only `ui/shortcut/actions.dart` reaches,
from a keyboard shortcut. Not a frame path.

**Two flagged items were left alone.** `_csi.params` could be a fixed
`Int32List` instead of a growable list, but Phase 5.4 measured that whole loop
and found reordering it worth nothing and batching it worth -8%, so there is no
reason to expect this one to pay. And `PacedTerminalWriter`'s unbounded queue
is real, but bounding it means either dropping output or a threshold mode with
an API surface - recorded as Phase 7, not something to slip into a cleanup.

## Against `xterm` and `xterm2` — 2026-09-03

The tables above compare this tree against its own earlier commits. This one
compares the published packages the line came from, which is the comparison a
reader of the README is actually asking about.

`script/cross_bench/` is its own package so that it can depend on all three at
once. Each is driven through `package:<name>/core.dart` — the headless half,
no Flutter — and all three expose the same `Terminal(maxLines:)`, `resize`,
`write`, so one harness reaches them with nothing per-package in the measured
path. Versions: `xterm` 4.0.0, `xterm2` 5.2.0 (the last published on that
line), `xterm3` 6.3.0. Grid 170x50, 10000 lines of scrollback, 32 MiB per
workload in 8 KiB chunks, AOT-compiled. Apple M1 Pro, macOS 26.5.1, Dart
3.12.2. One package per process; three interleaved rounds, medians below. The
spread across rounds was under 2% on every cell.

### Throughput, MiB/s

| workload | `xterm` 4.0.0 | `xterm2` 5.2.0 | `xterm3` 6.3.0 | vs `xterm` |
|---|---|---|---|---|
| ascii | 15.8 | 86.6 | **113.4** | 7.2x |
| ascii-long-lines | 16.6 | 117.8 | **135.5** | 8.2x |
| sgr | 18.8 | **60.8** | 57.4 | 3.1x |
| utf8 (Turkish) | 15.4 | 14.2 | **63.5** | 4.1x |
| cyrillic | 14.8 | 5.5 | **90.4** | 6.1x |
| altscreen | 19.2 | 133.2 | **139.1** | 7.2x |

`sgr` is the one row where `xterm3` is behind `xterm2`, by 6%, and it is a
known price rather than a surprise: 6.3.0's born-small `BufferLine` sizes a
line's store from its first write, and an SGR-heavy line arrives as several
short runs between colour changes, so a later run has to grow the store. The
6.3.0 changelog records the two alternatives measured against it, at -22% and
-14% elsewhere.

`utf8` and `cyrillic` are where the distance is real rather than incremental.
Both older packages leave the batched write path at the first non-ASCII letter,
so a language not written in ASCII never batches at all — `xterm2` is *slower*
than `xterm` on Cyrillic because the rest of its write path got faster around a
per-code-point loop that did not.

### Scrollback residency, MiB

10000 lines of `ls -l`-shaped output retained at a 170-column window, resident
set after the collector has been given its chances, minus the same process
before the terminal existed. Medians of five.

| | `xterm` 4.0.0 | `xterm2` 5.2.0 | `xterm3` 6.3.0 |
|---|---|---|---|
| scrollback RSS | 85.8 | 79.3 | **52.8** |

Lines here are about 90 columns wide in a 170-column window, so this is the
case born-small storage was built for: the line no longer reserves the 80
columns it never reaches.

### Resize reflow, ms

One narrow-and-restore pair (170 → 80 → 170 columns) with the scrollback full,
which rewraps all 10000 retained lines twice. Median of three runs of ten.

| | `xterm` 4.0.0 | `xterm2` 5.2.0 | `xterm3` 6.3.0 |
|---|---|---|---|
| per resize pair | 10.6 | 4.7 | **4.6** |

`xterm3` and `xterm2` are level here; the 2.3x is against `xterm`. Reflow has
not been worked on since, and this row is here to say so.

### What this does not measure

Everything above the terminal core. No renderer, no Flutter, no PTY — the
`flood` workload in the tables above is what says whether output starves the
frame pipeline, and it only exists for this tree. A cross-package render
comparison would need three example apps whose cell metrics agree, and cell
metrics are the thing this file already records as not stable across builds.

## Against Ghostty and Alacritty, end to end — 2026-11-19

Every table above stops at the terminal core. This one is the whole app: the
example app (`example/lib/e2e_bench.dart`, release build, `flutter_pty2`, Dart
`Utf8Decoder`) against Ghostty 1.4.0 and Alacritty 0.17.0 (built with cargo),
each running the same driver in a real PTY. Grid 100x37 in all three, checked
on every sample. 64 MiB per workload, five interleaved rounds, medians. Apple
M1 Pro, Flutter 3.50.0. Harness: `script/term_compare/`.

The clock stops on a DSR reply (`ESC[6n`) sent after the payload: the reply
can only come once every byte before it is parsed. It proves parsed, not
painted, and says nothing about input latency or frame pacing.

### Throughput, MiB/s

| workload | xterm3 | Alacritty | Ghostty |
|---|---|---|---|
| ascii | 77.0 | 62.5 | **144.9** |
| sgr | 39.1 | 54.4 | **95.4** |
| cursor (alt screen, CUP + short writes) | 42.9 | 65.7 | **97.6** |
| unicode (Turkish, CJK, emoji, box/braille) | 16.2 | 53.4 | **109.3** |

Ghostty's numbers are capped by the harness, not by Ghostty: a null terminal
that only answers DSR (`ceiling.py`) reaches 185–247 MiB/s through the same
PTY and Python driver.

### vtebench gets xterm3 wrong

vtebench 0.3.1 times how long `write_all` to the PTY blocks
(`src/bench.rs`) and never waits for the terminal. The example app reads the
PTY into an unbounded Dart stream, so vtebench measures how fast that buffer
fills: xterm3 comes out level with or ahead of both (`scrolling` 16 ms against
44 and 32), and then the window stays frozen for about three minutes while
the backlog drains. On the `unicode` payload above the gap is visible in one
run: bytes accepted in 0.5 s, parsed at 4.0 s.

### Where the time goes

Sampled per thread during the run: the main thread sits at ~97% of one core,
the process at ~115%. Activity Monitor shows this as 11–20% of the machine,
which reads as idle CPU but is one saturated core. On macOS the Dart UI
isolate runs on the platform thread, so UTF-8 decode, parsing, layout and
paint are serialised on it; frames only happen in the gaps parsing leaves,
which is the stutter. Ghostty reads and parses on its own thread and renders
on another.

### Next steps

1. **Parse off the UI thread.** The fix for the stutter, not for throughput
   (see *Where the `unicode` time goes* below):
   decode and parse in a separate isolate and hand the UI thread something it
   only has to paint. Architectural — `Terminal` state is read directly by the
   renderer today. A spike was measured and not pursued: *Frame starvation
   through a PTY* below.
2. **Profile the `unicode` path.** Done: *Where the `unicode` time goes* and
   *Grapheme-join fast paths* below. The largest gap (6.7x to Ghostty, 3.3x to
   Alacritty). The headless core does Turkish at 63.5 MiB/s (table above), so
   the cost is in CJK/emoji/wide cells, the paint path, or both — split the
   payload by script before guessing.
3. **Backpressure.** Measured (*Frame starvation through a PTY* below): on
   `flutter_pty2` 1.0.0, `ackRead` gives full frame rate and no backlog, and
   costs 48-76% of throughput, because every ~1 KiB read waits for its own
   ack. The coalescing plugin of item 5 changes that: its output credits
   throttle the producer without an ack per read.
4. **`PacedTerminalWriter`.** Did nothing through a PTY until `996a7b4`: its
   budget was per drain pass, and a PTY delivers one chunk per pass. See
   *`PacedTerminalWriter` paces across turns* below. No throughput gain.
5. **Coalesce reads in `flutter_pty2`.** Exists on an unreleased local branch
   of flutter_pty2 3.0.0 and was measured: *flutter_pty2 with coalesced reads*
   below.

## Where the `unicode` time goes — 2026-11-19

Step 2 of the list above. `script/term_compare/gen.py` also writes one payload
per script class in `unicode`'s line shape — `latin-ext`, `cyrillic`, `cjk`,
`emoji` (with ZWJ sequences, skin tones, flags and VS16), `combining`
(Devanagari, Arabic with harakat, decomposed Latin) and `box` — so each row is
one ingredient of the mixed payload. 64 MiB per payload, 100x37, AOT, Apple M1
Pro. Every LF goes in as CRLF, which is what the PTY's ONLCR hands the
terminal; with bare LF the column never resets and the fast rows read about
25% low.

Everything in this section was measured on `8e2b14b`, before the changes in
the next one.

### The core, headless

`script/unicode_layer_probe.dart`, no Flutter. Each file in 64 KiB chunks
through a chunked `Utf8Decoder` (`decode`); the decoded strings through
`EscapeParser` with the no-op handler (`parser`), through `Terminal.write` with
10000 lines of scrollback (`full`), and the same with DEC mode 2027 off
(`no-graph`). Five interleaved rounds, medians, MiB/s:

| payload | decode | parser | full | no-graph |
|---|---|---|---|---|
| ascii | 1156 | 585 | 122.9 | 124.5 |
| unicode | 248 | 114 | 19.4 | 39.3 |
| latin-ext | 290 | 462 | 158.7 | 167.6 |
| cyrillic | 284 | 434 | 157.5 | 165.0 |
| cjk | 364 | 130 | 15.3 | 33.2 |
| emoji | 308 | 128 | 9.2 | 25.1 |
| combining | 204 | 89 | 7.4 | 19.1 |
| box | 363 | 491 | 219.5 | 222.6 |

**Read across a row, not down a column.** MiB/s counts bytes, and the bytes
per code point differ by class: ascii 1.00, latin-ext and cyrillic 1.84,
combining 2.08, unicode 2.54, box and cjk 2.69, emoji 3.44. Per code point,
`full` is 128.9 M/s on ascii, 90.2 on latin-ext, 89.5 on cyrillic, 85.6 on box
— and then 8.0 on unicode, 6.0 on cjk, 3.7 on combining and 2.8 on emoji.
Everything that stays on the batched path (*Batched writes for alphabets other
than English*) is within about 1.5x of ASCII; everything that leaves it is an order
of magnitude behind.

On the four slow rows, taking the columns as time per byte: grapheme
clustering (`full` against `no-graph`) is 47-62% of the core's time (decode
plus `full`), the per-code-point buffer path (`no-graph` against `parser`)
29-34%, the parser 7-16% and decode 3-7%.

### Discriminators

`script/term_compare/gen_synthetic.py` writes six payloads that each hit one
case of `Buffer._joinsPreviousGrapheme`. 32 MiB each, three interleaved rounds,
medians, MiB/s:

| payload | decode | parser | full | no-graph |
|---|---|---|---|---|
| c-wide-only (kana, kanji) | 424.5 | 159.4 | 25.3 | 37.2 |
| c-wide-narrow (each followed by `a`) | 382.1 | 88.6 | 12.2 | 26.7 |
| c-hangul-only (syllables) | 425.4 | 160.5 | 11.5 | 37.4 |
| c-emoji-only | 414.9 | 170.7 | 14.4 | 29.2 |
| c-emoji-narrow (each followed by `a`) | 402.6 | 100.4 | 12.8 | 23.9 |
| c-latin-combining (`e` + U+0301 and kin) | 358.5 | 70.6 | 6.8 | 11.6 |

Each row points at one gap in the join check as it stood. Its fast exit for
wide characters required a wide base, a wide code point and no marks in the
cell, so `c-wide-only` loses only a third to clustering while a wide character
after a narrow letter fell through to segmentation (`c-wide-narrow`, 12.2
against 26.7). The same exit excluded every Hangul code point: `c-hangul-only` has the
same bytes per code point and the same parser speed as `c-wide-only`, and runs
at less than half its speed. Emoji paid two `wcwidth` calls on the way to that
exit, each a binary search above the BMP. And every combining mark went to the
segmenter (`c-latin-combining`, 6.8 against 11.6).

### The app

`example/lib/e2e_bench.dart`, release build, with two switches added for this:
`XB_NOVIEW=1` mounts no `TerminalView` (the terminal is sized to 100x37 by
hand, so the run is PTY, decode and `Terminal.write` with no layout or paint),
and `XB_PROF=<file>` records the time spent inside `terminal.write` at each DSR
reply and every frame's build and raster time. Three legs per round,
interleaved — view with profiling, no view with profiling, view without — and
three rounds; all 72 samples were 100x37. Medians:

| payload | view MiB/s | no view MiB/s | wall s | in `write` s | frames |
|---|---|---|---|---|---|
| ascii | 71.8 | 75.9 | 0.89 | 0.62 | 4 |
| unicode | 15.8 | 16.1 | 4.06 | 3.62 | 1 |
| latin-ext | 73.8 | 72.2 | 0.87 | 0.45 | 4 |
| cyrillic | 73.7 | 73.8 | 0.87 | 0.47 | 4 |
| cjk | 13.0 | 13.0 | 4.93 | 4.59 | 1 |
| emoji | 7.9 | 7.9 | 8.11 | 7.74 | 1 |
| combining | 6.1 | 6.3 | 10.41 | 9.93 | 1 |
| box | 87.5 | 90.8 | 0.73 | 0.36 | 5 |

Wall, `write` and frames are the profiled view leg: frames is how many were
drawn while that payload streamed. Frame build time is 0-2% of wall on every
row.

**The cost is in the core, not in layout or paint.** Taking `TerminalView`
away moves no row by more than 6%. On the four slow payloads, decode plus the time inside
`terminal.write` is 96-98% of the main thread's wall time. Decode is not
measurable in the app — it runs in the stream transform before `write` — so
that share is derived: decode seconds come from the headless probe's
`decode-1k` column (64 MiB at 1 KiB chunks), not from the app.

**The PTY hands `terminal.write` about 1 KiB per call,** not the 64 KiB the
driver writes (`XB_PROF` counts calls). The probe's `-1k` columns run the same
files at that size; it changes `full` by under 5% on every row, so the headless
table stands for the app.

**Parsing off the UI thread would fix the stutter, not the throughput.** The
slow payloads get one frame in a 4-10 s burst, and a parser isolate would give
those frames back. But the stream is sequential: another core parses it at the
same rate, and the payload drains no sooner. Throughput has to come out of the
core, which is the next section.

```sh
mkdir -p /tmp/pay
python3 script/term_compare/gen.py 64 /tmp/pay
python3 script/term_compare/gen_synthetic.py 32 /tmp/pay
# /tmp/ulp-base: the probe built at 8e2b14b, recipe in the next section
/tmp/ulp-base 5 /tmp/pay/{ascii,unicode,latin-ext,cyrillic,cjk,emoji,combining,box} > /tmp/probe.txt
/tmp/ulp-base 3 /tmp/pay/c-*
(cd example && flutter build macos --release -t lib/e2e_bench.dart)
script/term_compare/run_app.sh /tmp/pay /tmp/app 3
python3 script/term_compare/app_table.py /tmp/app /tmp/probe.txt
```

Built here, the app measures this tree, not `8e2b14b`. The app table as it
was needs the example built in the same worktree, with
`example/lib/e2e_bench.dart` and `script/term_compare/` copied in and
`run_app.sh` run from that copy.

## Grapheme-join fast paths — 2026-11-19

`Buffer._joinsPreviousGrapheme` decides whether a code point continues the
cluster in the cell before it. Whatever its exits do not settle goes to
`characters` segmentation, which allocates. Each change below adds or widens an
exit that is decided by the incoming code point, its width and the last code
point the previous cell stores, and each holds because of one rule of UAX #29:

- **The known cell width is passed in.** `writeChar` has already looked up
  `wcwidth(codePoint)`; the check looked it up again, which above the BMP is a
  binary search.
- **A wide code point joins only after Prepend, a leading jamo or ZWJ.** No
  wide code point is Extend (bar the emoji modifiers, which have their own
  check), Hangul V or T, a regional indicator or an Indic consonant, so only
  GB9b, GB6 and GB11 can attach one to the cluster before it, and each is
  decided by the last code point stored. Replaces the wide-after-wide exit,
  Hangul exclusion and both `wcwidth` calls.
- **A zero-width Extend or ZWJ always joins, unless the cell ends in a
  control.** GB9 attaches them to anything; GB4 is the exception, and a cell
  can end in a control — U+2028 is width 1, and with mode 2027 off any
  zero-width code point is stored. `zeroWidthExtends` takes whole stretches,
  Greek to Mongolian, minus Prepend, controls, Hangul V and T, and the marks
  the width table knows from a newer Unicode than the segmenter.
- **A narrow letter joins only by GB9b or GB9c.** `isNarrowLetter` — Hebrew to
  NKo, Thai, Lao, Georgian, the Latin and Greek extended blocks, and the
  independent vowels and consonants of the ten Indic blocks — is no Extend,
  jamo, regional indicator or pictograph, so it starts a new cluster unless the
  cell ends in Prepend or holds a conjunct linker. It runs after the Indic
  conjunct check, which can join pairs GB9c does not.
- **Indic vowel signs join.** At width 1, the dependent vowel signs at offsets
  0x3E-0x4C of Devanagari to Malayalam are SpacingMark or Extend (GB9a, GB9),
  bar the unassigned code points between them.
- **A valid emoji modifier joins.** Past the modifier-base check a modifier is
  Extend, so GB9 applies.
- **The line is read once.** `currentLine` goes through the circular buffer on
  every call, and the check called it up to three times; `_previousCellIndex` is
  inlined into the same read.
- **Plane 1 gets a width table.** `wcwidth` binary-searched everything above
  the BMP. Plane 1, where nearly every emoji lives, now has a 64 KiB table like
  the BMP's, filled in `wcwidth`'s own precedence, combining over wide.

Baseline `8e2b14b` against this tree, headless, three interleaved passes,
medians, MiB/s. 64 MiB per `gen.py` payload, 32 MiB per `c-*`:

| payload | full before | full after | ratio | no-graph before | no-graph after |
|---|---|---|---|---|---|
| ascii | 111.4 | 114.7 | 1.03 | 112.2 | 112.9 |
| unicode | 18.9 | **35.6** | 1.88 | 37.7 | 40.1 |
| latin-ext | 147.5 | 149.2 | 1.01 | 145.7 | 146.9 |
| cjk | 14.8 | **27.2** | 1.84 | 32.0 | 33.1 |
| emoji | 8.9 | **13.8** | 1.55 | 24.7 | 32.4 |
| combining | 7.1 | **12.7** | 1.79 | 18.4 | 18.7 |
| box | 202.4 | 204.9 | 1.01 | 205.3 | 196.9 |
| c-wide-only | 24.4 | 29.8 | 1.22 | 35.5 | 34.9 |
| c-wide-narrow | 11.8 | **23.1** | 1.96 | 25.6 | 25.8 |
| c-hangul-only | 11.0 | **30.0** | 2.73 | 35.5 | 35.6 |
| c-emoji-only | 13.9 | **37.3** | 2.68 | 28.1 | 45.5 |
| c-emoji-narrow | 12.4 | **27.6** | 2.23 | 22.6 | 31.2 |
| c-latin-combining | 6.5 | **10.5** | 1.62 | 11.0 | 11.2 |

`no-graph` rose on emoji because the plane-1 table speeds up `wcwidth`, which
runs in either mode. `full` on the rows that never reach the join check —
ascii, latin-ext, box — moved by 3% or less.

Step by step, `full` only, each step an interleaved A/B against the one before,
n=3 unless marked: width passed in, `c-emoji-only` 14.0 → 17.2; the wide exit
(first form, cells without marks), cjk 15.1 → 25.6, unicode 19.2 → 32.2,
`c-hangul-only` 11.1 → 27.5, `c-wide-narrow` 12.0 → 22.2; Extend and ZWJ,
combining 7.5 → 9.1, `c-latin-combining` 6.9 → 10.5; narrow letters, combining
9.1 → 11.5; Indic vowel signs, combining 11.2 → 12.0; the wide exit decided on
the last stored code point, emoji 10.3 → 11.3; emoji modifiers, emoji
11.2 → 11.6 (n=5); the plane-1 table, emoji 11.6 → 13.2, `c-emoji-only`
24.1 → 34.6; the line read once, `c-wide-only` 27.6 → 30.1, cjk 25.4 → 27.4
(n=5). Each pair is only good against itself: ascii drifted between 106 and
119 across these runs. They came from throwaway full-only builds of the probe,
so the repo scripts reproduce the table above, not these.

**What a code point pays before any exit.** With the width passed in,
`c-wide-only` ran at 24.7 MiB/s, and at 33.5 with the check returning at its
first line, though every one of its code points should leave at the first exit.
Returning early at successive points of the check priced the way there, at
that step, at about 30 ns per code point: finding the previous cell ~6 ns,
reading its code point and combining string ~9 ns, the checks ahead of the
wide exit ~10 ns, the exit itself ~4.5 ns.

### How it was accepted

`script/grapheme_grid_dump.dart` digests the grid a file leaves behind — code
point, width and combining string per cell, wrap flags, cursor — and
`script/term_compare/gen_corpus.py` writes a 335-file adversarial corpus:
every class in isolation, targeted sequences (jamo, Prepend, ZWJ, regional
indicators, VS15/VS16, modifiers, virama), lines filled to the edge, nearly
every code point after each of 27 bases, and slices of the payloads above. Old binary
against new, the digests were identical in four configurations (100x37 and
7x10, mode 2027 on and off), checked after every change. Deliberately broken
variants changed 8-21 files' digests, so the oracle does catch errors. Each
predicate also has an exhaustive test over U+0000-U+10FFFF against real
segmentation, the plane-1 table one against the binary search it replaces.
Tests 1079 → 1094, all passing.

What that does not cover: the digest leaves out cell attributes and the
pending-wrap state. The numbers are headless; the app is measured under *In
the app* below.
And the width table is Unicode 17 while `characters` 1.4.1 segments by
Unicode 16 — `zeroWidthExtends` works around the difference (U+1ACF-1AEB), and
the exhaustive tests will flag it when either side moves.

**Measured, rejected:** skipping the `runes.length` count in
`BufferLine.addCombiningCharacter` for short strings. combining 1.025x at n=5 —
nothing.

### What is left

On mixed and CJK text the join check is nearly exhausted: `unicode` 35.6
against 40.1 with clustering off. Emoji sequences (13.8 against 32.4: emoji
after ZWJ, a regional indicator after a finished flag, the VS16 resize path)
and combining scripts (12.7 against 18.7: scripts the predicates do not cover,
a consonant after a virama, a `Map<int, String>` lookup and a string concat per
mark) still have a gap. One lead not pursued: a small direct-mapped cache of
`(base, codePoint)` pairs for cells with no combining string.

```sh
# Baseline binaries. The two scripts do not exist at 8e2b14b, so they are
# copied in, as bench-compare.sh copies its harness.
git worktree add --detach /tmp/xb 8e2b14b
cp script/grapheme_grid_dump.dart script/unicode_layer_probe.dart /tmp/xb/script/
(cd /tmp/xb && dart pub get &&
  dart compile exe script/grapheme_grid_dump.dart -o /tmp/dump-base &&
  dart compile exe script/unicode_layer_probe.dart -o /tmp/ulp-base)
git worktree remove --force /tmp/xb
dart compile exe script/grapheme_grid_dump.dart -o /tmp/dump
dart compile exe script/unicode_layer_probe.dart -o /tmp/ulp

python3 script/term_compare/gen_corpus.py /tmp/pay /tmp/pay /tmp/corpus
script/term_compare/grid_oracle.sh /tmp/corpus /tmp/dump-base /tmp/dump /tmp/oracle
script/term_compare/probe_ab.sh /tmp/ulp-base /tmp/ulp 3 /tmp/ab.log \
  /tmp/pay/{ascii,unicode,latin-ext,cjk,emoji,combining,box} \
  /tmp/pay/c-{wide-only,wide-narrow,hangul-only,emoji-only,emoji-narrow,latin-combining}
```

### In the app — 2026-11-20

The example app (`e2e_bench.dart`, release, real PTY, view on, no profiling)
built before `7be44d3` (at `8e2b14b`) and after it, alternated one round at a
time. 64 MiB per payload, 100x37, five rounds, medians, MiB/s:

| payload | before | after | ratio |
|---|---|---|---|
| ascii | 76.4 | 77.6 | 1.02 |
| unicode | 16.0 | **27.7** | 1.73 |
| latin-ext | 75.8 | 76.5 | 1.01 |
| cyrillic | 75.2 | 76.0 | 1.01 |
| cjk | 13.1 | **23.6** | 1.81 |
| emoji | 7.9 | **12.2** | 1.55 |
| combining | 6.2 | **11.3** | 1.81 |
| box | 88.6 | 88.9 | 1.00 |

The app gets what the headless table promised: 1.55-1.81x on the four rows
that reach the join check, against 1.55-1.88x headless, and the rows that never
reach it within 2%.

```sh
# Base build: the harness does not exist at 8e2b14b, so it is copied in, as
# bench-compare.sh copies its harness. Keep the bundle named example.app.
git worktree add --detach /tmp/xb 8e2b14b
cp example/lib/e2e_bench.dart example/lib/e2e_worker.dart /tmp/xb/example/lib/
(cd /tmp/xb/example && flutter build macos --release -t lib/e2e_bench.dart)
mkdir -p /tmp/app-base && cp -R /tmp/xb/example/build/macos/Build/Products/Release/example.app /tmp/app-base/
git worktree remove --force /tmp/xb
(cd example && flutter build macos --release -t lib/e2e_bench.dart)
mkdir -p /tmp/app-new && cp -R example/build/macos/Build/Products/Release/example.app /tmp/app-new/
script/term_compare/app_ab.sh /tmp/pay /tmp/appab /tmp/app-base /tmp/app-new 5
python3 script/term_compare/app_ab_table.py /tmp/appab/results.jsonl
```

Built here, the new side is this tree, which also has `996a7b4` and the bench
flags of `c717fec`; with no flag set neither is on this path.

## Frame starvation through a PTY — 2026-11-20

`flood` (*Pacing the write path*) has no PTY, and there the unpaced case drew 37
frames a second and was never freezing. Through a real PTY it does freeze. The
example app (`e2e_bench.dart` with `XB_PROF`, release, `flutter_pty2` 1.0.0,
view on) draws **1-8 frames during a whole 64 MiB payload**, and the longest
gap between two frames is **0.2-2.8 s** — every unpaced run in this section and
the next two. All tables here: real PTY, 64 MiB per payload, 100x37, Apple M1
Pro, display at 75 Hz, five interleaved rounds, medians.

**The cause, measured.** `flutter_pty2` 1.0.0 posts one port message per
`read()`, and a macOS PTY returns about 1 KiB per read: 0.99 KiB per
`terminal.write` call. The messages arrive far faster than they are parsed. The
driver has handed over all 64 MiB after 0.5-0.8 s, with 5-53 MiB still
unparsed at that point (derived), and the UI thread spends the rest of the
payload draining that backlog. Split where the driver finished writing
(`spike_phase.py`, run 3 below), every unpaced frame falls in the burst; the
tail — 1.8 s on unicode, 2.3 s on cjk — draws none. Peak RSS is up to 106 MiB
above the same run with `ackRead` (unicode 304 against 198 MiB).

### Levers on flutter_pty2 1.0.0

Each cell is MiB/s / frames during the payload / longest gap between frames, ms.
Two runs; compare only within one table.

Run 1:

| config | ascii | unicode | cjk |
|---|---|---|---|
| unpaced | 77.4 / 4 / 405 | 27.7 / 1 / 1586 | 22.9 / 1 / 2545 |
| `ackRead`, ack after parsing (`ack`) | 18.9 / 254 / 14 | 12.8 / 374 / 16 | 11.8 / 408 / 15 |
| `ackRead`, ack on arrival (`ack-early`) | 20.3 / 237 / 15 | 16.3 / 293 / 15 | 15.1 / 317 / 14 |
| `PacedTerminalWriter` before `996a7b4` | 71.2 / 3 / 457 | 26.6 / 1 / 2341 | 22.0 / 1 / 2619 |
| the same + `ackRead` | 19.6 / 245 / 15 | 15.5 / 308 / 15 | 14.6 / 330 / 14 |
| isolate, snapshot pulled per frame, acked (`isolate`) | 33.6 / 142 / 14 | 17.5 / 271 / 14 | 15.2 / 316 / 14 |
| the same, ack on arrival (`isolate-early`) | 36.2 / 132 / 14 | 21.6 / 222 / 17 | 18.9 / 254 / 14 |

Run 3 (run 2 repeated `ack-early` and `isolate-early` within 7%):

| config | ascii | unicode | cjk |
|---|---|---|---|
| unpaced | 75.0 / 5 / 316 | 27.1 / 1 / 2257 | 22.8 / 1 / 2700 |
| isolate, snapshot pushed (`isolate-push`) | 65.7 / 74 / 17 | 26.0 / 188 / 17 | 21.5 / 228 / 17 |
| budget across turns, 8 ms (`paced-span`) | 55.3 / 92 / 24 | 23.2 / 239 / 54 | 19.8 / 314 / 26 |
| budget across turns, 11 ms (`paced-span11`) | 59.8 / 64 / 28 | 23.8 / 178 / 67 | 20.4 / 226 / 35 |

**Back pressure works, and on 1.0.0 it is expensive.** `ackRead` holds the
display's 75 fps with a longest gap of 14-16 ms and no backlog, at 48-76% less
throughput (ascii 77.4 → 18.9, unicode 27.7 → 12.8, cjk 22.9 → 11.8): every
~1 KiB chunk waits for its own ack round trip. Acking on arrival recovers part
of it and nothing else changes.

**The shipped `PacedTerminalWriter` did nothing.** Never more than one chunk
queued (`pendingChunks` max 1), frames and gaps as unpaced. Its budget was per
drain pass, and a pass ended when the queue was empty: a PTY delivers one chunk
per event-loop turn, so every pass wrote its one chunk and returned, and the
budget was never reached.

**A budget that spans turns does work.** `paced-span` is a bench-only pacer
(`XB_PACED=2`) that sums the time spent in `Terminal.write` across chunks and
queues whatever arrives past the budget until after the frame: the longest gap
goes from 0.3-2.7 s to 24-54 ms, at 13-26% of throughput. An 11 ms budget buys
some throughput back and lengthens the gaps. Both still take everything the PTY
delivers into their queue — up to 62039 chunks.

**An isolate is smooth and buys no throughput.** `isolate-push`: a worker
isolate owns the PTY and a headless `Terminal`, and pushes a 100x37 snapshot of
the visible grid at most every 13 ms to a mirror `Terminal` that the view
shows. Longest gap 17 ms on every payload, at 88-96% of unpaced throughput in
that run. No gain, because the stream is sequential and another core parses it
at the same rate, and the backlog is as unbounded as unpaced (20-53 MiB
unparsed when the driver finishes). A snapshot is 59.2 KB and takes ~22 us to
build in the worker; applying it on the UI thread took 59-67 us in runs 1 and 2
and 87-92 us in run 3, and a snapshot reached the UI a median 0.1-0.2 ms after
it was requested. Run 2's `isolate-push` was smooth but less so — 61.4 / 77 / 26,
24.7 / 192 / 27, 20.6 / 232 / 27 — and the data does not show whether that
build differed from run 3's.

**Not pursued.** The spike mirrors only the visible cells. A real
implementation would have to carry scrollback, combining characters, the
hyperlink table, input, resize, selection and search across the isolate
boundary; answer the callbacks a `Terminal` makes synchronously today (queries
the application answers inline); keep the modes input encoding depends on
(keyboard protocol, mouse reporting, bracketed paste) in step on the UI side;
and keep today's path regardless, because the web has no isolates. For a
smoothness gain that a budget across turns delivers on the UI thread, at no
throughput gain, that is not worth it — the next section is that budget in the
package.

```sh
python3 script/term_compare/gen.py 64 /tmp/pay
(cd example && flutter build macos --release -t lib/e2e_bench.dart)
script/term_compare/spike.sh /tmp/pay /tmp/spike1 5 "unpaced ack ack-early isolate isolate-early"
script/term_compare/spike.sh /tmp/pay /tmp/spike3 5 "unpaced isolate-push paced-span paced-span11"
python3 script/term_compare/spike_table.py /tmp/spike1   # also: backlog, RSS, snapshot costs
python3 script/term_compare/spike_phase.py /tmp/spike3   # burst / tail split
```

The two writer rows were taken before `996a7b4`. At this tree `paced` is the
fixed writer, so the old row reproduces only as `paced-old` with `APP_OLD` set
to a build at `ba46f04` (recipe as under *In the app*), and the old writer with
`ackRead` has no config.

## `PacedTerminalWriter` paces across turns — 2026-11-20

`996a7b4` makes the budget per frame. Time spent inside `Terminal.write` is
summed across `write()` calls, and once `frameBudget` (8 ms) of it has been
spent since the last frame, further chunks are queued until a frame has been
produced. The check is made before a chunk is written, never after: with a PTY
the chunk that has to wait arrives on a later turn. A chunk arriving after a
frame interval (17 ms) with no write starts a fresh budget and is written at
once — the frame is inferred from the idleness — so ordinary interactive output
is not delayed. If the frame waited for has not come within 100 ms, the writer
stops waiting for it and, until it comes, leaves one frame interval between
budgets, so a window whose frames have stopped keeps draining and replies the
terminal owes still go out. Public API unchanged.

Acceptance, one interleaved run, MiB/s / frames / longest gap ms:

| config | ascii | unicode | cjk |
|---|---|---|---|
| unpaced | 72.1 / 8 / 206 | 26.4 / 2 / 1825 | 22.3 / 1 / 2747 |
| writer before `996a7b4` | 67.9 / 6 / 318 | 25.6 / 1 / 2321 | 21.4 / 2 / 2847 |
| writer after | 53.6 / **100 / 19** | 22.9 / **245 / 48** | 19.4 / **322 / 23** |
| `paced-span`, for reference | 55.4 / 93 / 22 | 23.0 / 240 / 51 | 19.7 / 316 / 22 |

The writer now lands on the bench-only pacer: throughput within 4%, frames and
gaps alike. Against unpaced in the same run it costs 13-26% of throughput and
takes the longest gap from 0.2-2.7 s to 19-48 ms. The binary measured here
differed from what shipped only in the no-frame fallback below, which a 48 ms
gap does not reach; a second run of the shipped code gave 54.6 / 97 / 24,
22.9 / 245 / 50 and 19.5 / 322 / 23.

**Measured, rejected:** when no frame comes, yielding one event-loop turn
between budgets instead of a frame interval. Measured with a `waitForFrame`
that never completes while the window stays visible (`XB_PACED=3`): 57.0 /
26.0 / 21.8 MiB/s, but longest gaps of 260 / 1039 / 1364 ms — back-to-back
budgets starve the frames as unpaced output does. With the frame interval that
shipped, the same setup gives gaps of 102 / 51 / 33 ms at 25.4 / 9.6 / 7.3
MiB/s, about a third of unpaced. So a window whose frames have stopped, or
whose frames the writer does not hear about, drains at about a third of the
normal rate. A truly hidden window was not measured.

What this does not cover. Tests 1104, all passing. With a visible window the
100 ms timeout has not been seen to matter: the longest gap in any round of the
fixed writer was 63 ms on ascii, unicode and cjk and 87 ms on `sgr` (next
section), on one machine. Whether it fired was not counted. There is still no back pressure in the class: the queue takes
everything the PTY delivers, up to 59034 chunks here, about 57 MiB at 0.99 KiB
a chunk (derived). How long input takes to show its effect — a Ctrl-C's output
behind that queue — was not measured. And the class stays opt-in: nothing in
the package uses it.

```sh
# paced-old: a build at ba46f04, recipe as under *In the app*, into /tmp/app-old
APP_OLD=/tmp/app-old/example.app/Contents/MacOS/example \
  script/term_compare/spike.sh /tmp/pay /tmp/accept 5 "unpaced paced-old paced paced-span paced-noframe"
python3 script/term_compare/spike_table.py /tmp/accept
```

At this tree `paced-noframe` is the shipped fallback. The zero-delay variant
was a throwaway build — `_waitForNextFrame` arming `Timer(Duration.zero, ...)`
instead of `Timer(_frameInterval, ...)` — and is not in the repo.

## flutter_pty2 with coalesced reads — 2026-11-20

Old: `flutter_pty2` 1.0.0 from pub.dev, which the example depends on. New: a
**local, unreleased** checkout of flutter_pty2 3.0.0 at `2c525c8` (branch
`perf/coalesce-output-reads`), in which reads are coalesced into events of up to
64 KiB, output flow is controlled by automatic credits with a 256 KiB window,
and pausing the stream subscription withholds credit. These are numbers for
that commit, not for a release. Both builds are this tree with the fixed
writer; "writer" below is `PacedTerminalWriter` as of `996a7b4` in every row.

MiB/s / frames / longest gap ms:

| config | ascii | unicode | cjk | sgr |
|---|---|---|---|---|
| 1.0.0, unpaced | 75.3 / 5 / 348 | 27.2 / 1 / 2264 | 22.9 / 1 / 2781 | 37.6 / 2 / 1185 |
| 1.0.0, writer | 55.6 / 95 / 22 | 23.2 / 241 / 54 | 19.9 / 318 / 25 | 6.3 / 177 / 83 |
| 3.0.0 local, unpaced | 77.4 / 16 / 149 | 28.6 / 18 / 296 | 24.6 / 18 / 259 | 27.8 / 18 / 243 |
| 3.0.0 local, writer | 65.5 / 92 / 16 | 25.5 / 209 / 24 | 22.1 / 274 / 13 | 7.0 / 156 / 69 |
| 3.0.0 local, writer + pause | 64.6 / 93 / 14 | 25.5 / 208 / 25 | 22.1 / 274 / 14 | 7.1 / 157 / 66 |

KiB per `terminal.write` call / peak PTY bytes queued in the writer, MiB:

| config | ascii | unicode | cjk | sgr |
|---|---|---|---|---|
| 1.0.0, unpaced | 0.99 / – | 0.99 / – | 0.99 / – | 0.99 / – |
| 1.0.0, writer | 0.99 / 29.4\* | 0.99 / 59.5\* | 0.99 / 58.9\* | 0.99 / 60.8\* |
| 3.0.0 local, unpaced | 38.4 / – | 19.8 / – | 13.3 / – | 22.2 / – |
| 3.0.0 local, writer | 34.2 / 0.5 | 44.6 / 12.0 | 42.8 / 16.3 | 31.1 / 0.4 |
| 3.0.0 local, writer + pause | 34.9 / 0.5 | 43.5 / 1.0 | 41.5 / 1.0 | 31.0 / 0.4 |

\* derived: peak queued chunks × KiB per write.

**Unpaced, the producer is throttled.** The driver's writes now return only as
fast as the terminal parses — accepted and parsed are the same 2.23 s on
unicode — so nothing piles up: at most 0.3 MiB unparsed when the driver finishes,
against 12-52 MiB on 1.0.0, and peak RSS 283 → 216 MiB on unicode. Frames go
from 1-5 to 16-18 per payload and the longest gap from 0.3-2.8 s to 149-296 ms:
better, not smooth. Throughput moves +3-7% on ascii, unicode and cjk.

**With the writer** the gaps on ascii, unicode and cjk are 13-25 ms and
throughput is 10-18% above the writer on 1.0.0. But the writer still takes everything it is given, and on
unicode and cjk its queue peaks at 12.0 and 16.3 MiB: that is growth over a
64 MiB payload, not a bound.

**Pausing the subscription bounds it.** A bench-only rule in
`e2e_bench_pty3.dart` (`XB_PAUSE=1`): pause the output subscription above 1 MiB
queued in the writer, resume below 256 KiB. Peak queue at most 1.0 MiB on every
payload, and throughput, frames and gaps where they were without it. The pause
only engaged on unicode and cjk, 46-54 times per run, so what it costs on
ascii and `sgr` has not been exercised.

**`sgr` with the writer is slow on either plugin**, 6.3 and 7.0 MiB/s, because
one frame of that payload takes 44-52 ms to build (median per frame, in every
`sgr` row; under 2 ms on ascii), so 156-177 frames fill most of the window. In one
diagnostic run, 178 frames' builds summed to 8.9 s of a 10.5 s window. A paint
cost, under investigation. It is also why unpaced `sgr` got slower on the new
plugin: it draws 18 frames instead of 2, about 0.8 s of build at ~44 ms each,
and the payload took 0.6 s longer (derived).

The 3.x entrypoint is not part of the example, because the example depends on
`flutter_pty2: ^1.0.0` and CI analyzes it against that: it lives in
`script/term_compare/pty3/`, excluded from analysis, and is copied in for the
build.

```sh
# Both binaries: recipe at the top of script/term_compare/spike_pty3.sh
APP=/tmp/pty3/example.app/Contents/MacOS/example APP_OLD=/tmp/pty1/example.app/Contents/MacOS/example \
  PAYLOADS="ascii unicode cjk sgr" script/term_compare/spike_pty3.sh /tmp/pay /tmp/pty3run 5
PAYLOADS="ascii unicode cjk sgr" python3 script/term_compare/spike_table.py /tmp/pty3run
```

## Against Ghostty again — 2026-11-20

The 2026-11-19 comparison, re-run with the writer as an extra xterm3 leg. Same
driver, PTY and 100x37 grid; five interleaved rounds, medians, MiB/s. Two runs;
compare only within one table.

Run 1, `flutter_pty2` 1.0.0, writer as of `996a7b4`:

| workload | xterm3 | xterm3 + writer | Ghostty 1.4.0 |
|---|---|---|---|
| ascii | 72.8 | 53.2 | **101.7** |
| sgr | 36.5 | 6.1 | **71.2** |
| cursor | 41.8 | 31.6 | **78.8** |
| unicode | 26.4 | 22.2 | **85.6** |

Run 2, the local flutter_pty2 3.0.0 build of the previous section, writer +
pause:

| workload | xterm3 | xterm3 + writer + pause | Ghostty 1.4.0 |
|---|---|---|---|
| ascii | 75.5 | 63.3 | **127.5** |
| sgr | 25.9 | 6.9 | **89.0** |
| cursor | 40.5 | 36.2 | **91.0** |
| unicode | 28.1 | 24.9 | **103.5** |

**Read the ratios as approximate.** Ghostty's own numbers moved 15-25% between
the two runs, and run 1 sits 19-30% below the 2026-11-19 table, with the same
Ghostty 1.4.0. xterm3's ascii and cursor rows stayed within 6% across all
three; its unicode row moved with the grapheme work, and its `sgr` row with the
frame cost of the previous section. The unicode gap to Ghostty was 6.7x on
2026-11-19 and is 3.2x and 3.7x in these two runs.

Throughput only: the clock is the DSR reply, and Ghostty's frames were not
measured, so the writer columns have no Ghostty counterpart for smoothness. No
Alacritty column: no binary was available on the day.

```sh
python3 script/term_compare/gen.py 64 /tmp/pay
# Results land next to the payloads, so each run gets its own copy.
mkdir -p /tmp/cmp1 /tmp/cmp2
cp /tmp/pay/{ascii,sgr,unicode,cursor} /tmp/cmp1/ && cp /tmp/pay/{ascii,sgr,unicode,cursor} /tmp/cmp2/
(cd example && flutter build macos --release -t lib/e2e_bench.dart)
script/term_compare/cmp_paced.sh /tmp/cmp1 5
# /tmp/pty3: the 3.x build, recipe at the top of script/term_compare/spike_pty3.sh
APP=/tmp/pty3/example.app/Contents/MacOS/example TAG=-pty3 PAUSE=1 \
  script/term_compare/cmp_paced.sh /tmp/cmp2 5
```

### What is left

- **Frame build cost on SGR-dense screens.** 44-52 ms per frame on `sgr` is
  what holds the writer to 6-7 MiB/s there, and what slows unpaced `sgr` once
  frames happen at all. It is paragraph-cache misses,
  because colour is in the per-cell cache key, and as far as measured it is
  confined to synthetic random colour (*Frame build on colour-dense screens*,
  next). Whether to adopt the glyph atlas measured there is open.
- **The per-code-point write path**, where the largest throughput gap to
  Ghostty is: 3.2-3.7x on unicode, against 1.9-2.2x on cursor and 1.4-1.7x on
  ascii.
- **An adaptive budget for the writer** when frames are expensive. It has lost
  the case that motivated it: real coloured output builds a frame in 0.3-2.5 ms
  (next section). An idea, not measured.
- **The pause logic in the package.** The bench's pause-above / resume-below
  rule bounds the queue on the 3.x plugin; it could live in
  `PacedTerminalWriter` or alongside it rather than in each application. An
  idea, not measured as a package change.
- **`combining`**: 8 ms of build and 56 paragraph layouts per frame, and a
  longest gap of 237-283 ms even with the writer (next section). Not
  investigated.

## Frame build on colour-dense screens — 2026-11-20

Why one `sgr` frame takes 44-52 ms to build (*flutter_pty2 with coalesced
reads*), whether real programs pay it, and four ways out, tried in scratch
copies of `lib/`. Every number here: the example app (`e2e_bench.dart`),
release, real PTY, `flutter_pty2` 1.0.0, 100x37, `PacedTerminalWriter` on
(`XB_PACED=1`) so that every frame is drawn, Apple M1 Pro, macOS, Impeller.
Build and raster are medians over the frames inside the payload's DSR window,
ms; raster is raster-thread CPU time. Two flags of `e2e_bench.dart` used here
are uncommitted bench code at the time of writing: `XB_STATS=1` records
`TerminalRenderStats` after every frame, and `XB_SHOT` writes a screen into the
terminal and dumps the view to PNG. So are the helpers
`script/term_compare/gen_sgr_ablate.py`, `rec_pty.py` and `shot_diff.py`.

### The cause: colour is in the paragraph cache key

`TerminalPainter.paintCellForeground` draws one `ui.Paragraph` per non-empty
cell, cached under `(foreground ARGB, decoration ARGB, visual flags, cell
content, text scaler, combining characters)`. Capacity is max(2048, cells ×
1.25) with cells = columns × (rows + 1): 4750 at 100x37. The lookup is per
cell, not per style run: with ligatures off, the default, the run path is never
taken.

A hit costs about 0.7 us including `drawParagraph` (ascii: 1.7 ms over 2478
lookups, derived). A miss costs about 27 us, timed with stopwatches in a
scratch copy of `lib/` on `sgr`:

| step of one miss | us |
|---|---|
| `ParagraphBuilder` construction, with style conversion | 6.6 |
| `pushStyle` | 5.4 |
| `addText` | 0.3 |
| `build` | 2.4 |
| `layout` | 8.2 |
| cache insert + evict + dispose | 3.5 |

The stopwatches perturb a little: `sgr` builds in 47.3 ms stock and 47.6-48.2
instrumented. In that copy (`sgr`, median frame 47.6 ms), `RenderTerminal.paint`
is 47.5 ms, of which the foreground pass 47.3 and the background pass 0.11;
`performLayout` is 0.00.

**Ablation.** `gen_sgr_ablate.py` makes variants of `gen.py`'s `sgr` payload,
one change each (the generator's comments say exactly what); the last three
rows are real captures repeated to the same size. 16 MiB per variant, three
rounds; lookups and misses are per frame.

| variant | build ms (median / p90) | raster ms | lookups | misses |
|---|---|---|---|---|
| ascii | 1.7 / 2.1 | 2.7 | 2478 | 0 |
| `sgr` | 47.3 / 51.6 | 3.3 | 1829 | 1656 |
| fix8: 8 colours, attributes accumulate | 30.7 / 35.0 | 3.3 | 1814 | 915 |
| fgonly: foreground colour only | 33.0 / 38.1 | 3.2 | 1826 | 1107 |
| bgonly: background colour only | 20.4 / 25.2 | 3.2 | 1828 | 604 |
| fg256: 256-colour foreground only | 31.9 / 36.4 | 3.2 | 1792 | 1074 |
| attrs: attributes, no colour | 3.2 / 4.4 | 3.5 | 1818 | 0 |
| bold, italic or inverse alone | 1.3 / 1.5 | 2.0 | 1810-1847 | 0 |
| underline alone | 2.7 / 3.1 | 3.9 | 1829 | 0 |
| reset: `ESC[0m` before every run | 24.0 / 26.8 | 2.7 | 1835 | 1113 |
| samesgr: fixed SGR sequence, random text | 1.9 / 2.9 | 2.3 | 1823 | 0 |
| sametext: random SGR, fixed text | 25.7 / 28.1 | 3.2 | 1884 | 1230 |
| runs1: 1 style run per line | 26.9 / 30.8 | 3.7 | 2934 | 1284 |
| runs4 | 58.3 / 62.6 | 4.3 | 2818 | 2220 |
| runs15 | 59.4 / 62.7 | 4.3 | 2224 | 2096 |
| runs40 | 40.0 / 42.7 | 4.5 | 1486 | 1398 |
| `git log -p --color` | 1.0 / 1.7 | 1.3 | 1028 | 1 |
| `ls -laG` | 1.6 / 2.2 | 2.2 | 1906 | 0 |
| clang diagnostics | 1.3 / 2.0 | 2.0 | 1818 | 0 |

**The number of misses decides it, not the number of style runs.** Frame build
is about 1.3 ms + 20-32 us × misses per frame (derived from the rows above).
`samesgr` has as many runs as `sgr` and builds in 1.9 ms; `runs1` has one run
per line and takes 26.9 ms, because its colours are random. Attributes without
colour never miss. `fix8` shows that a bounded palette can still thrash:
colours times accumulating attributes times characters came to 13224 distinct
keys over the run (counted, see the next table), against a capacity of 4750,
and half its lookups miss.

**Ceilings**, from throwaway switches in the instrumented copy — the output is
wrong, so these are bounds, not candidates. Baselines are that copy's: `sgr`
48.2, `fix8` 31.4 ms.

| switch | `sgr` build ms | `fix8` build ms |
|---|---|---|
| none | 48.2 | 31.4 |
| colour removed from the key | 2.8 | 2.7 |
| cache capacity × 100 | 39.6 | 6.6 |

Capacity helps `fix8` and barely moves `sgr`, whose key space is unbounded and
which does not reach a steady state within 16 MiB. Menlo with an empty fallback
list, instead of the default 24-family `fontFamilyFallback`: `sgr` 47.0 → 37.6.
The background pass switched off: no change.

### Real 256-colour and truecolor output does not hit it

Captured from tools installed on the machine: vim 9.1 with `termguicolors` and
unokai, and with 256-colour habamax, over this repo's sources, both as a
recorded TUI session (`vim_*`, `rec_pty.py`) and as a `tmux capture-pane -e`
stream (`vimcat_*`); htop 3.5.1; `rg --colors` with truecolor; `git log -p
--color-moved` with truecolor `color.diff.*`; and the `cmatrix` and
256-colour-table fixtures. **Not installed, therefore not measured:** bat,
delta, eza, lsd, vivid, nvim, btop, tig, lazygit, pygmentize, chroma, lolcat —
in particular no gradient or rainbow tool.

Keys are counted in a scratch copy that records every key looked up (median
distinct keys in one frame, and distinct keys over the whole run); misses (mean
per frame) and build come from the stock leg of the candidate run below.

| payload | keys per frame | keys over the run | misses per frame | build ms |
|---|---|---|---|---|
| vim_unokai | 78 | 292 | 3 | 0.5 |
| vim_habamax256 | 76 | 310 | 4 | 0.5 |
| vimcat_unokai | 99 | 280 | 3 | 0.9 |
| vimcat_habamax256 | 103 | 286 | 3 | 1.0 |
| htop | 214 | 271 | 1 | 1.2 |
| rg_true | 89 | 136 | 1 | 1.5 |
| git_true | 101 | 532 | 9 | 0.8 |
| cmatrix | 143 | 536 | 4 | 0.3 |
| colors256 | 389 | 728 | 0 | 2.5 |
| `sgr` | 1716 | 66649 | 1662 | 46.1 |
| `fix8` | 1585 | 13224 | 922 | 30.3 |

Every real capture stays at or under 728 keys over the run, against a capacity
of 4750: a theme's palette is 10-20 colours. Read the misses column with care:
the captures are repeated 4-900 times to fill the payload, which flatters misses
per frame; the count of keys over the run is the evidence. So the 45-50 ms frame
is, as far as measured, a property of synthetic random colour — and, untested,
perhaps of gradient tools — not of highlighters and TUIs.

### Four candidates, in scratch copies

None of this is in the package; the code is
`script/term_compare/paint_spike/candidates.patch`, switched by environment
variables (`lib/src/ui/xc.dart` in the patch).

- **A1** cache capacity × 2, × 4, × 16 (`XC_CACHEX`).
- **A2** `memo`: memoise the converted `ui` styles on a miss (`XC_MEMO=1`).
- **A3** `nofb`: a short fallback list for printable ASCII (`XC_NOFB=1`).
- **B** `tint`: a colour-independent paragraph, drawn inside a `saveLayer` with a
  `srcIn` colour filter per style run (`XC_TINT=1`).
- **C** `atlas`: glyph sprites in a `ui.Image` atlas, drawn with `drawRawAtlas`
  once per line, `BlendMode.modulate` (`XC_ATLAS=1`).
- **D** `runls`: one paragraph per style run on a miss, letter spacing set to
  cell width minus advance (`XC_RUN=1 XC_RUNLS=1`).

B and C key a glyph by a 3-bit luminance bucket (`XC_LUM=1 XC_LUMMODE=2`, next
subsection). Two interleaved rounds, medians, build / raster ms
(`paint_spike/main_table.txt`):

| payload | stock | A3 `nofb` | B `tint` | C `atlas` | D `runls` |
|---|---|---|---|---|---|
| `sgr` | 46.1 / 3.1 | 37.7 / 3.2 | 16.7 / 9.0 | 1.5 / 4.7 | 11.9 / 1.1 |
| `fix8` | 30.3 / 3.2 | 24.9 / 3.3 | 8.7 / 8.6 | 1.2 / 0.5 | 11.8 / 1.1 |
| reset | 24.1 / 2.7 | 18.8 / 2.6 | 2.4 / 11.3 | 0.5 / 0.4 | 11.9 / 1.0 |
| ascii | 1.7 / 2.7 | 1.7 / 2.7 | 1.7 / 3.7 | 0.7 / 0.5 | 3.5 / 0.6 |
| gitlog | 1.0 / 1.3 | 1.0 / 1.3 | 1.1 / 2.5 | 0.5 / 0.3 | 2.8 / 0.8 |
| htop | 1.2 / 1.9 | 1.3 / 2.0 | 1.6 / 9.5 | 0.4 / 0.3 | 1.0 / 1.0 |
| vim_unokai | 0.5 / 0.6 | 0.5 / 0.6 | 0.5 / 1.5 | 0.3 / 0.2 | 0.9 / 0.4 |
| colors256 | 2.5 / 3.9 | 2.6 / 4.2 | 2.6 / 5.2 | 0.8 / 0.6 | 1.3 / 1.8 |

Paragraph layouts per frame on `sgr`: stock 1662, `nofb` 1663, `tint` 417,
`atlas` 75, `runls` 326. The scratch copy with every switch off (`base`)
matches stock (`sgr` 45.8 / 3.2). The table also has ls, clang, vimcat_unokai,
git_true and cmatrix, and `paint_spike/extra_table.txt` rg_true and the two
habamax captures; they read like the real rows above.

A1, build ms (`paint_spike/a1_table.txt`):

| payload | × 1 | × 2 | × 4 | × 16 |
|---|---|---|---|---|
| `fix8` | 30.2 | 15.8 | 6.8 | 6.6 |
| `sgr` | 45.8 | 45.3 | 43.8 | 39.3 |
| peak RSS on `sgr`, MiB | 279 | 339 | 457 | 1041 |

**A2 does nothing**: `sgr` 46.4, `fix8` 30.7, within noise.

**A1 helps bounded palettes only, and costs memory.** `fix8` falls to 6.8 ms at
× 4; `sgr` stays at 39-45 ms while RSS reaches 1041 MiB at × 16.

**A3 is pixel-identical and cuts 18-22% of the build on the colour-dense
payloads** (`sgr` 46.1 → 37.7, `fix8` 30.3 → 24.9, reset 24.1 → 18.8; derived),
with the controls unchanged. But the spike hard-codes `SF Mono,Menlo` as the
short list; a real version would have to derive it from the configured font.

**B is rejected.** It moves the cost to the raster thread on every payload —
one layer per colour run: htop raster 1.9 → 9.5 ms, reset 2.7 → 11.3, ascii
2.7 → 3.7. This file has now recorded that lesson three times: work taken off
the UI thread has to be measured on the raster thread.

**D is rejected as measured.** The controls build slower — ascii 1.7 → 3.5,
gitlog 1.0 → 2.8 — because cells drawn as part of a run never warm the per-cell
cache. Without the letter-spacing compensation (`XC_RUN=1` alone), runs drift
0.17 px per glyph, the spike's check rejects them back to the per-cell path,
and `sgr` takes 75.9 ms.

**C is the only candidate that lowers both build and raster on every payload
measured, controls included** — build 1.5-3x and raster 1.5-8x lower on the
real and control rows (derived) — because it also replaces about 2500
`drawParagraph` calls per frame with one atlas call per line. The one exception
is `sgr`'s raster while the atlas pages fill: median 4.7 against 3.1, p90 build
/ raster 7.6 / 11.6; in the second half of the run it is 1.0 / 0.5.

### What the atlas does to pixels

The repo's golden tests render with the Flutter test font, whose glyphs are
boxes, so they cannot see a glyph-level difference. The oracle is a PNG of the
real app instead: `shot_diff.py` shoots five screens (plain, `sgr`,
decorations, wide characters, vim) at device pixel ratio 1 and 2, the first
three also under a selection, and diffs them pixel by pixel. Stock is
deterministic: two shots are identical.

| screen | A1 / A2 / A3 | atlas, white sprites | atlas, luminance bucket |
|---|---|---|---|
| plain, ± selection | identical | identical | identical |
| vim | identical | 2398-5071 px, max 53 | identical |
| wide | identical | 3398-7240 px, max 54 | identical |
| `sgr`, ± selection | identical | 38142-92397 px, max 91 | 6723-15078 px, max 2 at DPR 1, 5-6 at DPR 2 |
| decorations | identical | 26275-55443 px, max 76 | 2790-6133 px, max 14 |
| decorations + selection | identical | 29765-62420 px, max 73 | 3649-7112 px, max 32 |

Pixels that differ, and the largest difference in any channel (0-255). White
sprites tinted to the cell's colour are wrong in edge antialiasing: the glyph
mask Impeller produces depends on the text colour. Keying the sprite by a 3-bit
luminance bucket — the top 3 bits of `(54r + 183g + 19b) >> 8`, the sprite drawn
in that bucket's grey — is what the tables above measured. With it, plain, vim,
wide and a held-out screen not used while tuning are identical; `sgr` differs by
at most 2 per channel at DPR 1 and 5-6 at DPR 2, with no pixel off by more than
16; decorations by at most 14. Decorations under a selection differ by up to 32,
with 739-1321 pixels off by more than 16, only on curly, dotted and dashed
underlines — unexplained.
(White sprites are also cheaper, `sgr` 0.6 / 0.5, because one sprite serves
every colour; they are not a candidate.)

What the spike's atlas covers: printable ASCII, Latin-1, Latin Extended-A and
-B, Greek and Cyrillic; single-cell, no combining characters, glyph fits the
cell; decorations when the decoration colour equals the foreground. Left on
today's path: an explicit underline colour (SGR 58), combining characters,
wide characters (CJK, emoji — emoji are never tinted), symbols, arrows and PUA
glyphs, procedural glyphs, and everything when ligatures are on.

### What it buys in throughput

An overnight run: stock against the atlas candidate, five interleaved rounds,
the writer on. The `gen.py` payloads are 64 MiB, gitlog and vimcat_unokai about
16 MiB.

| payload | MiB/s | frames | longest gap ms | build ms | raster ms |
|---|---|---|---|---|---|
| ascii | 56.1 → 62.9 | 94 → 91 | 24 → 20 | 1.7 → 0.7 | 2.6 → 0.5 |
| unicode | 23.7 → 24.0 | 240 → 240 | 76 → 75 | 1.0 → 0.9 | 2.1 → 1.6 |
| cjk | 20.3 → 20.0 | 311 → 314 | 46 → 46 | 0.8 → 0.8 | 1.5 → 1.4 |
| emoji | 10.3 → 10.3 | 641 → 641 | 40 → 40 | 0.8 → 0.8 | 1.3 → 1.3 |
| combining | 5.5 → 5.6 | 666 → 661 | 283 → 237 | 8.0 → 8.1 | 2.0 → 1.9 |
| `sgr` | 6.6 → 32.4 | 175 → 176 | 89 → 77 | 46.1 → 0.7 | 3.2 → 0.5 |
| gitlog | 36.1 → 37.7 | 40 → 41 | 22 → 21 | 1.1 → 0.5 | 1.3 → 0.3 |
| vimcat_unokai | 36.1 → 37.1 | 43 → 43 | 24 → 19 | 0.9 → 0.5 | 1.3 → 0.3 |

Outside `sgr` the throughput gain with the writer is between -1% and +12%
(derived), because parsing, not painting, owns the thread. CJK, emoji and
combining text are outside the spike's allowlist and do not move. `combining`
shows something else: 8 ms of build per frame (56 paragraph layouts per frame on
either build) and a longest gap of 237-283 ms even with the writer. Not
investigated.

### Status and limits

Nothing from this spike is in the package. The decision — adopt an atlas, and
whether opt-in, or stop paint work here — is open. *(Later: adopted as an opt-in, see* Glyph atlas,
opt-in.*)*

- Two rounds for the candidate table.
- The atlas was tuned while looking at `sgr` and `fix8` (page capacity,
  padding), so the real-payload rows are the trustworthy ones.
- No eviction: the cap is 8192 sprites. `sgr` reaches about 6000 (6013 after
  16 MiB, 6016 after 64 MiB), about 35 MiB at DPR 2; real content 94-372
  sprites, 0.5-2.1 MiB. A steady state on `sgr` is not proven.
- macOS and Impeller only. Text gamma and the luminance-bucket rule are
  unverified on Android, iOS, Windows, Linux and the web, as is
  `toImageSync` on the web.
- Verified only at whole-device-pixel cell origins, with nearest sampling.
- Active hyperlinks and blink were not captured.
- Raster figures are raster-thread CPU time; GPU cost was not measured.

```sh
# Payloads: the sgr ablations, 16 MiB each; real_dir holds captures (gitlog,
# ls, clang) that are repeated to the same size.
python3 script/term_compare/gen_sgr_ablate.py 16 /tmp/abl /tmp/real
# A real program through a 100x37 PTY; reply-triggering queries are stripped.
python3 script/term_compare/rec_pty.py /tmp/vim 'x60*\x06,:qa!\r' -- vim -u NONE -N -i NONE \
  -c 'syntax on' -c 'set tgc nu' -c 'colo unokai' lib/src/ui/painter.dart
# One paced process per payload per round, per-frame render stats in prof_*.jsonl.
(cd example && flutter build macos --release -t lib/e2e_bench.dart)
T=$PWD/script/term_compare; O=/tmp/abl-run; mkdir -p $O
APP=example/build/macos/Build/Products/Release/example.app/Contents/MacOS/example
for r in 1 2 3; do for p in ascii sgr fix8; do
  env XB_W=800 XB_H=600 XB_PACED=1 XB_STATS=1 XB_PROF=$O/prof_${p}_$r.jsonl \
    XB_ARGS="$T/drive.py|$p#$r|$O/results.jsonl|/tmp/abl/$p" $APP
done; done
# Pixel oracle: SCREENS holds raw terminal bytes, one file per screen.
python3 script/term_compare/shot_diff.py shot STOCK.app SCREENS /tmp/shot/stock
python3 script/term_compare/shot_diff.py shot CAND.app SCREENS /tmp/shot/atlas XC_ATLAS=1 XC_LUM=1 XC_LUMMODE=2
python3 script/term_compare/shot_diff.py diff /tmp/shot/stock /tmp/shot/atlas
```

The candidate builds need the patch applied to a copy of the package (`patch
-p1 < script/term_compare/paint_spike/candidates.patch` in the copy's root) and
the example built against that copy; the switches are read from the
environment at startup. What does not reproduce from the repo as it stands: the
candidate tables' layout and key counts came from a scratch `e2e_bench.dart`
that appends the patch's `XC` counters to each stats row, and from scripts that
join the stats to per-frame medians. Both are kept as they were, scratch paths
and all, under `script/term_compare/paint_spike/tools/`; the screens and the
real captures are in `screens/` and `captures/` beside them.

## One pass per CSI — 2026-11-20

The leftover of *CSI parameter bulk scanning*: one scan per sequence, not per
parameter. `EscapeParser._tryFastCsi` runs right after an ESC is consumed. If
what follows in the head block is `[`, then only digits, `;` and `:`, then a
final byte, it parses the parameters with locals in one loop, consumes the
sequence with one `consumeAsciiCodeUnits` and calls the handler: `m` and `H`
directly, the rest through `_csiHandlers`. Anything else - a private prefix,
an intermediate or control byte, a sequence that runs past the head block or
past 256 bytes - makes it return having consumed nothing, and
`_processEscape` parses it as before. It leaves `_csi` as `_consumeCsi` does.

What it removes per sequence: the `_pendingEscape` round trip, the prefix
peek, a `consume()` and five range tests per byte, and two table lookups to
reach the handler. A throwaway version that tried the fast path at the start
of every token cost ascii's parser 5-7% (every CR and LF paid two getters and
a call); trying it only after an ESC takes that to nothing (below).

Headless, `write_budget_probe`, `4cc07c2` against this change, five
interleaved passes, medians, MiB/s with the min-max of the five:

| payload | mode | before | after | speedup | ns/byte |
|---|---|---|---|---|---|
| sgr | parser | 94.9 (94.7-95.0) | 169.1 (168.4-169.9) | 1.78 | −4.40 |
| sgr | full | 65.3 (64.5-65.5) | 92.5 (90.8-93.1) | 1.42 | −4.29 |
| cursor | parser | 98.6 (97.0-100.7) | 172.9 (169.9-174.0) | 1.75 | −4.16 |
| cursor | full | 69.9 (69.6-70.4) | 100.1 (99.7-100.6) | 1.43 | −4.13 |
| truecolor | full | 74.7 (74.3-75.1) | 128.8 (127.5-129.2) | 1.72 | −5.35 |
| ascii | parser | 696.2 (693.6-697.1) | 698.1 (689.1-698.9) | 1.00 | 0.00 |
| ascii | full | 126.4 (125.2-126.8) | 126.4 (125.6-127.9) | 1.00 | 0.00 |
| ascii-utf8 | full | 122.3 (121.4-123.2) | 121.3 (120.2-123.4) | 0.99 | +0.06 |
| unicode | full | 40.1 (40.1-40.6) | 40.3 (40.0-40.4) | 1.00 | −0.07 |
| cjk-real | full | 32.1 (32.0-32.3) | 32.2 (31.8-32.3) | 1.00 | −0.13 |

`truecolor`, `ascii-utf8` and `cjk-real` are new in `gen.py`: a lolcat-style
24-bit foreground per character; ASCII with a non-ASCII character about every
150 bytes; and Han and kana with ideographic punctuation and fullwidth forms.
`full-1k` moves with `full` (sgr −4.10, cursor −3.91, truecolor −5.08).

In the app (`e2e_bench.dart`, release, `flutter_pty2` 1.0.0, view on, real
PTY, 100x37), the two builds and Ghostty 1.4.0 interleaved, five rounds, MiB/s:

| payload | before | after | ns/byte | Ghostty | gap before | gap after |
|---|---|---|---|---|---|---|
| sgr | 48.0 | 60.8 | −4.19 | 89.8 | 1.87x | 1.48x |
| cursor | 54.9 | 73.0 | −4.30 | 96.7 | 1.76x | 1.32x |
| truecolor | 58.1 | 82.0 | −4.79 | 113.4 | 1.95x | 1.38x |
| ascii | 78.4 | 78.4 | 0.00 | 152.6 | 1.95x | 1.95x |
| unicode | 29.7 | 29.5 | +0.27 | 107.0 | 3.60x | 3.63x |

The app gets what the core saves, byte for byte. `unicode`'s +0.27 is inside
the two builds' ranges (29-30 against 29-29).

**Accepted on.** Tests 1125, all passing. `terminal_state_dump.dart` - grid,
attributes, modes, cursor, every callback and reply, under eleven ways of
splitting each file into writes - is byte-identical before and after on the
`gen_parser_corpus.py` corpus plus 1 MiB of `truecolor` and `cjk-real` and a
file of edge cases for this path: sequences of 254-258 bytes after `[`, 30-40
parameters, values above 65535, colon separators, empty parameters, prefixes
and intermediates, C0, ESC, CAN, SUB and C1 inside a sequence, every final
byte, and input that ends right after ESC or inside a sequence (59 files, 649
digests). Two deliberately broken variants - the value clamp removed, the
parameter cap lowered by one - changed 69 and 24 digests, so the oracle sees
this path.

```sh
python3 script/term_compare/gen.py 64 /tmp/pay
git worktree add --detach /tmp/xb 4cc07c2
(cd /tmp/xb && dart pub get && dart compile exe script/write_budget_probe.dart -o /tmp/wbp-base &&
  dart compile exe script/terminal_state_dump.dart -o /tmp/tsd-base)
git worktree remove --force /tmp/xb
dart compile exe script/write_budget_probe.dart -o /tmp/wbp-new
dart compile exe script/terminal_state_dump.dart -o /tmp/tsd-new
script/term_compare/wbp_ab.sh /tmp/wbp-base /tmp/wbp-new 5 /tmp/ab.log parser,full,full-1k \
  /tmp/pay/{sgr,cursor,truecolor,ascii,ascii-utf8,unicode,cjk-real}
python3 script/term_compare/gen_parser_corpus.py /tmp/corpus --payloads /tmp/pay --payload-mib 1
cp script/term_compare/fastcsi_edges.txt /tmp/corpus/
/tmp/tsd-base /tmp/corpus/* > /tmp/tsd-base.txt; /tmp/tsd-new /tmp/corpus/* > /tmp/tsd-new.txt
cmp /tmp/tsd-base.txt /tmp/tsd-new.txt
```

The table above also had 1 MiB of `truecolor` and `cjk-real` and two files
ending after ESC and inside a sequence in the corpus. The in-app run is
`cmp_paced.sh`'s shape with the paced leg replaced by the second build.

## Wide characters in text runs — 2026-11-20

CJK, kana and Hangul took the per-code-point path one character at a time:
`writeChar`, its width lookup, the grapheme join check and two `setCell`
calls for every character. `isWideRunUnit` names the wide BMP characters that
can be written in a run the way `isSingleCellPrintable` names the narrow ones:
CJK punctuation, kana, bopomofo, Hangul compatibility jamo, Han (Extension A
and the unified block), Hangul syllables, compatibility ideographs, vertical
and small forms, fullwidth forms - every one width 2 and joining no run
character either way, which a test checks for each of them against
segmentation.

When the parser's per-character path meets one, it takes it and the narrow
and wide run characters after it in the head block to
`Terminal.writeMixedWidthText`, through an interface that is not exported, so
handlers written against `EscapeTextHandler.writeText` still only see
single-cell text. `Buffer.writeMixedWidth` writes each stretch that fits on
the line with one `setMixedWidthCells`, and hands three cases to `writeChar`
as before: the first unit, which may join the cell before the run (a Hangul
syllable after a leading jamo, anything after Prepend or ZWJ); a wide unit with
one column left; and a wide unit at the margin, where `writeChar` asks about a
join before it wraps.

The single-cell run scan that every token goes through is left as it was.
Two earlier shapes put the wide test there - a combined narrow-and-wide scan,
then an inline check after every run - and each cost the controls 2-5% (sgr
and cursor, ranges disjoint), for a unicode gain of ×1.41 instead of the
×1.27 below: in this shape a run's narrow prefix is written on its own.

Headless, `write_budget_probe`, the one-pass CSI commit against this change,
five interleaved passes, medians, MiB/s with the min-max of the five:

| payload | before | after | speedup | ns/byte |
|---|---|---|---|---|
| unicode | 40.2 (40.1-40.5) | 51.4 (48.4-51.5) | 1.28 | −5.13 |
| cjk-real | 32.0 (31.6-32.2) | 77.4 (73.2-77.7) | 2.42 | −17.50 |
| cjk | 30.3 (30.2-30.5) | 79.8 (75.7-80.0) | 2.64 | −19.55 |
| emoji | 14.6 (14.5-14.7) | 14.6 (14.2-14.6) | 1.00 | +0.03 |
| combining | 14.0 (14.0-14.1) | 13.9 (13.6-14.0) | 0.99 | +0.53 |
| ascii | 127.5 (125.9-127.9) | 126.5 (124.7-127.5) | 0.99 | +0.06 |
| box | 230.2 (227.5-232.5) | 228.8 (226.8-235.9) | 0.99 | +0.02 |
| latin-ext | 173.7 (171.0-176.8) | 174.0 (172.5-175.9) | 1.00 | −0.01 |
| sgr | 92.0 (80.1-93.2) | 91.8 (90.8-92.3) | 1.00 | +0.03 |
| cursor | 99.6 (94.3-100.6) | 99.4 (99.3-101.2) | 1.00 | +0.01 |

`full` mode; `full-1k` moves with it. With the no-op handler (`parser` mode)
CJK and combining text are 3-4% slower: every character that reaches the
per-character path now pays a test for U+3000 and up.

In the app (`flutter_pty2` 1.0.0, view on, real PTY, 100x37), the two builds
and Ghostty 1.4.0 interleaved, five rounds, MiB/s:

| payload | before | after | ns/byte | Ghostty | gap before | gap after |
|---|---|---|---|---|---|---|
| unicode | 29.9 | 36.2 | −5.53 | 106.8 | 3.57x | 2.95x |
| cjk-real | 25.4 | 50.0 | −18.49 | 165.0 | 6.50x | 3.30x |
| cjk | 24.6 | 53.7 | −20.95 | 132.2 | 5.37x | 2.46x |
| emoji | 12.4 | 12.3 | +0.45 | 83.8 | 6.78x | 6.82x |
| ascii | 80.4 | 79.5 | +0.13 | 156.5 | 1.95x | 1.97x |
| sgr | 62.5 | 62.4 | +0.01 | 94.2 | 1.51x | 1.51x |

**Accepted on.** Tests 1133, all passing, among them a comparison of
`Terminal.write` against the same code points through `Terminal.writeChar` at
widths 1 to 9, after colour, underline colour, a ZWJ, a Prepend and a leading
jamo, inside DECSLRM margins with the cursor inside and beyond them, with
insert mode, autowrap off and DEC special graphics, and over existing wide
characters. `grid_oracle.sh` (351 files: the 335 of `gen_corpus.py`, 12
hand-written edge cases, slices of `cjk-real`, `ascii-utf8` and `truecolor`,
and every wide run unit) shows no file differing in any of its four
configurations, and `terminal_state_dump.dart` is byte-identical on 71 files
under eleven splits. Two deliberately broken variants changed 44 and 7 state
digests.

A review found what neither oracle could, since both run at 7 columns and
wider: in a one-column window with mode 2027 on, after `❤ ZWJ`, the run's
first `〰` joins the cluster without writing anything (it cannot be widened to
two columns), so the cell before the second still ends in ZWJ and the second
joins it too. The first version wrapped before asking. It now leaves a wide
unit at the margin to `writeChar`; the case is in the tests.

Left out: a run's narrow prefix could be taken into the mixed run, and the
first unit's join check could be cheaper than a full `writeChar` - together
the gap between ×1.27 and the ×1.41 the first shape measured.

## A UTF-8 decoder for bytes in — 2026-11-20

`Terminal.writeBytes(Uint8List)` decodes the program's output itself and
gives exactly what a chunked `Utf8Decoder(allowMalformed: true)` gives -
U+FFFD placement, a sequence split across chunks, a BOM at the start dropped
and one after it kept - which 3000 random streams of valid and malformed
bytes, each cut six ways, check against the SDK decoder.

Why it can be faster: the SDK decoder builds one two-byte string out of any
chunk that holds a non-ASCII byte, and building a two-byte string from
UTF-16 units costs 1.7 ns a unit in Dart (`String.fromCharCodes(Uint16List)`),
against 0.04 ns a byte for a one-byte string from `Uint8List`. So a mostly-
ASCII chunk is cut into ASCII runs (found four bytes at a time), each a one-
byte string, and the non-ASCII stretches between them, decoded by the SDK on
their own, and the pieces are joined - 0.34 ns a byte where the SDK takes
2.2. A dense chunk would make too many pieces; judged from its first 64 bytes
it goes to a loop into UTF-16 units instead, which is also faster than the SDK
on CJK, emoji and accented alphabets.

Headless, `write_budget_probe`, `full-dec` (`Utf8Decoder` + `write`) against
`full-bytes` (`writeBytes`), 1 KiB chunks, n=5, MiB/s:

| payload | Utf8Decoder + write | writeBytes | speedup |
|---|---|---|---|
| ascii | 111.6 | 113.5 | 1.02 |
| ascii-utf8 | 90.1 | 96.0 | 1.07 |
| latin-ext | 109.1 | 112.4 | 1.03 |
| cyrillic | 107.0 | 110.6 | 1.03 |
| box | 135.7 | 142.2 | 1.05 |
| unicode | 42.1 | 43.1 | 1.02 |
| cjk-real | 64.5 | 65.3 | 1.01 |
| sgr, cursor, truecolor, emoji, combining | | | 1.00-1.02 |

In the app (`XB_BYTES=1` against the same build without it, `flutter_pty2`
1.0.0, view on, five rounds), the gain mostly does not survive: ascii-utf8
69.4 → 71.0, ascii 79.8 → 81.6, sgr 61.3 → 62.7, box 90.6 → 92.2 MiB/s, and
latin-ext, cyrillic, unicode and cjk-real within 1%. The decoder was 2-7% of
the headless time; in the app it is a smaller share still.

## Where the app's extra time goes — 2026-11-20

The same `Terminal.write`, fed from memory inside the example app
(`XB_MEM`, no view, 1 KiB chunks through `Utf8Decoder`), took 1.35 ns a byte
longer on ascii than the headless probe, and the Faz 0 end-to-end runs put
up to 1.8 ns a byte between the app and a Dart command-line target on the
same PTY plugin. A CPU profile of the app (profile build, VM service sampler)
put a quarter of `Terminal.write` in allocating line storage
(`Uint32List`, runtime slow path, GC included).

The app against the CLI, ns per byte, five rounds each:

| payload | app, no scrollback | CLI, no scrollback | scrollback in the app | scrollback in the CLI |
|---|---|---|---|---|
| ascii | 6.00 | 6.20 | 3.86 | 2.00 |
| cjk-real | 13.06 | 12.90 | 2.79 | 1.80 |
| unicode | 20.97 | 20.65 | 2.64 | 2.01 |
| sgr | 9.74 | 9.86 | 1.71 | 1.30 |

"No scrollback" is `XB_MAXLINES=0` in the app and `scroll0` plus `decode-1k`
in the probe; the scrollback columns are the difference to 10000 lines. With
no scrollback the app is as fast as the CLI; all of the difference is in
keeping 10000 lines. A micro-benchmark run in both says the same from the
other side: a compute loop takes the same time, a 2 KiB store kept in a
10000-entry ring nearly the same, and a small object kept that way 26-30 ns
in the app against 15-19 in the CLI. The VM's GC flags in the app are the
defaults (new space up to 16 MiB). Not found: why the app's heap makes
retention dearer.

What this changes: the line storage levers are worth more in the app than
headless numbers say - a smaller cell (whose ceiling took the CLI's ascii
scrollback cost down 70%) and recycling evicted lines, which was rejected
twice on headless numbers only.

## Emoji — 2026-11-21

`emoji` was the widest gap left: 6.8x to Ghostty in the app. Split by kind
(`gen_emoji.py`, 16 MiB each), ns per code point, headless before this:

| payload | full | grapheme mode off | the grapheme rules' share |
|---|---|---|---|
| e-simple: one code point each | 91 | 76 | 15 |
| e-mod: skin tones | 157 | 77 | 80 |
| e-zwj: ZWJ sequences | 271 | 113 | 157 |
| e-flag: regional indicator pairs | 276 | 58 | 218 |
| e-vs16: text symbols with VS16 | 245 | 88 | 157 |

Two things, then. Flags, ZWJ sequences and the narrow symbols that take
VS16 (❤ ☀ ✔) passed every exit of `_joinsPreviousGrapheme` and went to
segmentation, three string allocations a code point. And a plain emoji,
which no rule joins to anything, took the per-character path all the same.

**Grapheme rules.** A regional indicator or an Extended_Pictographic code
point extends nothing, so only three rules can join one to the cluster
before, and each is decided by the cluster's last code points: GB9b after
Prepend, GB12/GB13 after an odd run of regional indicators, GB11 after
ExtPict Extend* ZWJ. `_regionalIndicatorJoins` and `_pictographJoins` decide
those before segmentation and hand back what they cannot - a cell holding a
sequence the rules do not expect, which mode 2027 toggled can leave, or a
lone surrogate as its base - to segmentation as before. They sit after the
existing exits: placed first, every code point paid for the
Extended_Pictographic lookup, and combining text lost 5%, plain emoji 7%.
`isExtendedPictographic` is the segmenter's own set (78 ranges), checked
against it for every code point.

**Emoji in text runs.** `isWideRunEmoji` - an Extended_Pictographic code
point above the BMP of width 2 - joins the wide run units of *Wide characters
in text runs*: no run character continues a cluster that ends in one, and
the marks that do attach to an emoji (skin tones, VS16, ZWJ) are no run
characters, so a run stops before them. A run that would hold one character
- an emoji before its skin tone - is not started: the code unit after it is
looked at first, and a skin tone or regional indicator is turned away before
anything else is asked. Without that, skin-toned text lost 6%; and CJK gains a
little from the same shortcut, at line ends.

Headless, `write_budget_probe`, `full`, the bytes-in decoder commit against
this change, five interleaved passes, MiB/s:

| payload | before | after | speedup | ns/byte |
|---|---|---|---|---|
| emoji | 14.5 | 17.9 | 1.23 | −12.22 |
| e-simple | 36.0 | 55.2 | 1.53 | −9.21 |
| e-mod | 22.2 | 22.1 | 1.00 | +0.07 |
| e-zwj | 12.5 | 14.7 | 1.18 | −11.40 |
| e-flag | 13.3 | 19.6 | 1.47 | −22.79 |
| e-vs16 | 11.1 | 15.6 | 1.40 | −24.52 |
| unicode | 51.2 | 61.2 | 1.20 | −3.06 |
| cjk-real | 76.7 | 84.9 | 1.11 | −1.19 |
| cjk | 78.6 | 84.5 | 1.07 | −0.84 |
| ascii, ascii-utf8, sgr, cursor, truecolor, combining, latin-ext, box | | | 0.99-1.01 | |

In the app (`flutter_pty2` 1.0.0, view on, real PTY, 100x37), the two builds
and Ghostty 1.4.0 interleaved, five rounds, MiB/s:

| payload | before | after | Ghostty | gap before | gap after |
|---|---|---|---|---|---|
| emoji | 12.2 | 14.9 | 83.0 | 6.83x | 5.56x |
| e-simple | 28.0 | 39.7 | 125.0 | 4.47x | 3.15x |
| e-mod | 18.2 | 18.0 | 98.6 | 5.42x | 5.47x |
| e-zwj | 10.5 | 12.6 | 84.8 | 8.07x | 6.75x |
| e-flag | 11.1 | 16.0 | 99.9 | 8.98x | 6.24x |
| e-vs16 | 9.4 | 13.2 | 74.7 | 7.91x | 5.64x |
| unicode | 36.1 | 42.0 | 109.4 | 3.03x | 2.60x |
| cjk-real | 49.1 | 54.1 | 155.9 | 3.18x | 2.88x |

**Accepted on.** Tests 1143, among them exhaustive checks of
`isExtendedPictographic` and `isWideRunEmoji` against segmentation, a test
that flags, ZWJ sequences, VS16, skin tones and tag sequences end up one
cluster per cell, write-versus-`writeChar` comparisons at widths 1-9 with
emoji, REP after an emoji, and the lone-surrogate case below.
`grid_oracle.sh` (356 files, now with a slice of each `e-*` payload) shows no
difference in any configuration, and `terminal_state_dump.dart` is identical
on 76 files under eleven splits. Four deliberately broken variants changed
53-363 state digests.

A review found one case: a cell whose base is a lone high surrogate and whose
combining string starts with a lone low one reads as an astral character to
segmentation, which sees the two as one string, but not to the new rules,
which read them apart. Only malformed UTF-16 passed to `write(String)` or
`writeChar` builds such a cell; the rules now leave a surrogate base to
segmentation, and the case is a test.

What is left: skin tones still cost 80 ns a code point in the grapheme rules
(`_isEmojiModifierBase` and `addCombiningCharacter`), and a ZWJ sequence pays
the per-character path for every code point in it.

## Recycling evicted lines, take three: large scrollbacks only — 2026-11-21

Takes one and two rejected recycling on headless numbers, where a fresh
`Uint32List` costs next to nothing and clearing a used one costs more. *Where
the app's extra time goes* then found that keeping 10000 lines costs the
example app about twice what it costs the command-line probe. So the
question was asked again in the app, with an evicted line's storage cleared
over `[0, _used)` and handed to the next new line (`BufferLine.takeStorage`,
`adoptStorage`). In-memory feed, no view, 1 KiB chunks, against the same
build without it:

| scrollback at 100 columns | ascii | cjk-real | sgr |
|---|---|---|---|
| 0 lines | 0.81 | 0.95 | 0.98 |
| 100-1000 | 0.80-0.82 | 0.95-0.96 | 0.98 |
| 3000 | 0.88 | 0.98 | 0.97 |
| 5000 | 1.00 | 1.04 | 1.05 |
| 7000 | 1.13 | 1.11 | 1.10 |
| 10000 | 1.19 | 1.07 | 1.08 |
| 20000 | 1.13 | 1.07 | 1.07 |

A line that falls off a small scrollback dies young, where allocating is close
to free; one that falls off a large one has left the young generation, and so
would its replacement. So `Buffer` recycles only when the scrollback holds at
least `recycleThresholdCells` cells (lines times columns): 700000, the 7000
lines above. That the crossover follows bytes rather than lines is an
assumption; only 100 columns was measured.

**Memory.** The storage goes to the next line whatever its size, and a line
grows one that is too small to its full width, so once the scrollback has
filled, every line's storage tends to the full width - the size every line
had before 6.3.0 sized lines to their text. At 10000 lines and 100 columns:
19.5 MiB of cells, against 10.8 (short lines with some long ones), 13.1 (CJK
prose), 14.0 (`sgr`) and 14.3 MiB (`ascii`) without recycling; at 213 columns
the full-width figure is about 34 MiB a terminal. A pool that handed a store
only to a line that would have allocated one of exactly its size kept memory
where it was, and kept little of the speed: ascii 1.06, and 0.97-0.99 on
output written in several runs a line, whose first, text-sized store misses
the pool and is grown anyway. Chosen: the speed.

**One trap on the way.** Keeping the spare stores in a `List<Uint32List>`
made every cell read and write in the package 7-9% slower, on output that
never recycled a line: what comes out of a generic list could be any
`Uint32List` - a view - as far as the compiler knows, so `BufferLine._data`
lost its concrete type. A field assigned only from `_data` keeps it.

In the app at 10000 lines (in-memory feed), against the emoji commit, five
rounds, MiB/s: ascii 95.8 → 111.4, ascii-utf8 81.8 → 92.3, latin-ext 96.6 →
105.1, sgr 82.9 → 89.9, cjk-real 64.8 → 70.5, unicode 46.1 → 47.5, short lines
with some long ones 62.1 → 86.2; cursor unchanged. Below the threshold each
new line pays a field check and the eviction a call: 1000 and 0 lines within
-1.5% to +0.1%. Headless, where the gains were losses in takes one and two:
sgr +6%, cjk-real +4%, unicode +2%, ascii +1%, nothing slower.

End to end (`flutter_pty2` 1.0.0, view on, real PTY, the bench's 10000-line
scrollback), the two builds and Ghostty 1.4.0 interleaved, five rounds:

| payload | before | after | Ghostty | gap before | gap after |
|---|---|---|---|---|---|
| ascii | 78.8 | 84.5 | 142.9 | 1.81x | 1.69x |
| ascii-utf8 | 69.4 | 73.4 | 133.5 | 1.92x | 1.82x |
| sgr | 60.9 | 64.6 | 92.8 | 1.52x | 1.44x |
| unicode | 41.3 | 42.8 | 108.1 | 2.62x | 2.53x |
| cjk-real | 53.0 | 54.4 | 153.2 | 2.89x | 2.82x |
| cursor, truecolor, emoji | | | | | unchanged |

**Accepted on.** Tests 1146, among them the last 8000 lines of a recycling
scrollback compared, text, colour and width, with a 30000-line one that never
evicts - a build that skips the clear fails it. `terminal_state_dump.dart`,
whose 10000-line scrollback recycles, is byte-identical on 77 files under
eleven splits. A review of every reader of an evicted line found none that
reads one after the eviction hook: selection and prompt anchors check that
their line is attached.

## Glyph atlas, opt-in — 2026-11-21

The atlas of *Frame build on colour-dense screens* is now in the package,
off by default: `TerminalStyle(useGlyphAtlas: true)`. `GlyphAtlas`
(`lib/src/ui/glyph_atlas.dart`) keeps the spike's rule - a sprite per glyph,
style and 3-bit luminance band, drawn in that band's grey and tinted with
`BlendMode.modulate` - and the painter sends a cell to it when it can.

What changed from the spike:

- **Coverage.** Single-cell ASCII, Latin-1, Latin Extended-A and -B, Greek and
  Cyrillic as before, and now wide characters too: the CJK, kana, Hangul and
  fullwidth units a text run takes, from a second atlas with two-cell sprites,
  leaving out the few with an emoji form. Still on the paragraph path:
  combining characters, emoji, symbols, procedural box drawing, an underline
  coloured apart from the text, curly, dotted and dashed underlines (up to 32
  levels off when tinted), framed and encircled cells, glyphs that do not fit
  their cell, and everything while ligatures are on.
- **Pages.** Each line with new glyphs adds a page; past 16 pages they are
  merged by copying every sprite into a dense grid, sprite `n` to cell `n`. The
  spike stacked the pages, one sprite row per line, and its merged image passed
  8192 pixels long before the 8192-sprite cap. The capacity - 8192 sprites, or
  fewer when that many tall sprites do not fit a page - is now enforced as
  sprites are added: a line that reaches it draws the rest of its new glyphs
  the normal way, and the next line starts over. A cell too large for a page
  gets no sprites at all.
- **Draw order.** Sprites are stamped in one `drawRawAtlas` call per page at
  the end of a line, so a glyph drawn the normal way (box drawing, an emoji)
  would have gone under its left neighbour's overhanging ink. Queued sprites
  are now flushed before every normal-path cell that is not a space. A space's
  underline is not flushed for: `sgr` keeps SGR 4 to the end of a line, and a
  flush at every underlined space took its median frame build from 5 to 6.4 ms.
  The flush that stays costs `sgr` about 1 ms of build against the spike-era
  build without it (3.8-5.5 → 4.9-5.3 ms per round), within its throughput
  noise.

Every number below: the example app, release, real PTY, 100x37, M1 Pro, macOS,
Impeller, same build with and without `XB_ATLAS=1`.

**Pixels** (`shot_diff.py`, eight screens at DPR 1 and 2, most also under a
selection): plain, vim, wide characters and a CJK screen (`zcjk`) identical;
`sgr` at most 2 levels a channel at DPR 1 and 5 at DPR 2, no pixel off by more
than 16; decorations 2-6; `lumedge`, saturated colours at the edges of
luminance bands, up to 28, with 47-356 pixels off by more than 16. The new
`screens/order` puts italic letters against block and box-drawing glyphs,
emoji and arrows in other colours, underlined spaces between coloured letters,
Latin against CJK, and framed cells: at most 1 level at DPR 1 and 3 at DPR 2.
A build without the flush differs from stock there in 24-36 pixels, up to 22
levels, so the screen sees the order; the cases left unflushed stay within
the 3 levels.

**Frames** (`flutter_pty2` 1.0.0, `XB_PACED=1`, three interleaved rounds;
build and raster are median ms over the frames in the DSR window):

| payload | build | raster | MiB/s |
|---|---|---|---|
| `sgr` | 48.1 → 5.1 | 3.3 → 0.6 | 12.1 → 32.7 |
| truecolor | 41.0 → 0.6 | 2.9 → 0.4 | 17.7 → 60.4 |
| ascii | 2.0 → 0.8 | 2.7 → 0.5 | 54.0 → 52.5 |
| vimcat_unokai | 1.3 → 0.9 | 1.4 → 0.3 | 50.3 → 55.6 |
| htop | 1.5 → 0.6 | 2.2 → 0.3 | 36.3 → 36.6 |
| gitlog | 1.3 → 0.8 | 1.4 → 0.3 | 38.9 → 38.6 |
| rg_true | 2.0 → 0.9 | 2.8 → 0.3 | 45.4 → 49.5 |
| cjk-zipf | 16.1 → 14.8 | 5.5 → 0.4 | 23.4 → 23.8 |

The last three rows are from the run before the space change, which touches
none of them; a run after the capacity change gave `sgr` 5.3 ms and 32.9
MiB/s, truecolor 0.6 and 58.8, ascii 0.7 and 56.1. On CJK the build barely moves: a 64 MiB stream of Zipf-distributed
Han keeps bringing glyphs not seen yet, and each is a layout either way; the
raster falls 14 times.

**End to end** (`flutter_pty2` 3.x, frames drawn during the payload; stock,
atlas, the same build without a view, and Ghostty 1.4.0 interleaved, five
rounds, MiB/s; the last column is what drawing still costs with the atlas,
ns/B):

| payload | Ghostty | stock | atlas | no view | gap stock | gap atlas | atlas − no view |
|---|---|---|---|---|---|---|---|
| truecolor | 104.0 | 19.6 | 83.7 | 103.2 | 5.29x | 1.24x | +2.1 |
| `sgr` | 91.7 | 18.2 | 41.9 | 83.5 | 5.04x | 2.19x | +11.3 |
| ascii | 139.0 | 76.6 | 90.5 | 109.6 | 1.81x | 1.54x | +1.8 |
| cursor | 92.2 | 69.7 | 81.4 | 87.7 | 1.32x | 1.13x | +0.8 |
| unicode | 105.1 | 41.2 | 42.0 | 48.0 | 2.55x | 2.50x | +2.8 |
| cjk-zipf | 158.8 | 28.3 | 29.1 | 78.4 | 5.61x | 5.46x | +20.7 |

Without a view, truecolor runs at Ghostty's speed: what is left of its gap is
drawing. `sgr` still pays 11 ns/B, from the sprites it keeps adding - random
styles on random colours make about 6000 - which are layouts like any other.
CJK pays 21 ns/B and the atlas does not help it: the cost there is laying out
glyphs not seen before, which the atlas does too. *(Later: laying new CJK glyphs out together took this to about 5 ns/B; see* CJK glyphs
laid out together.*)*

**Accepted on.** Tests 1153. The atlas tests compare it with the paragraph
path pixel for pixel at DPR 1 and 2 (within 8 levels: the test rasteriser's
tint rounds differently from a direct draw), after a hundred sprites have gone
through six merges (a build that leaves sprites where they were fails it), keep
every page within 8192 pixels while one line adds 200 sprites to an atlas that
holds 128 (stacking, or adding past the capacity, fails it), start over on the
next line, take no sprite for a cell wider than a page, and check that a box-drawing cell between
two letters is drawn between their two atlas calls (no flush fails it).

**Limits.**

- Off by default. The cost is exactness: a few levels on arbitrary 24-bit
  colour, up to 28 at band edges.
- macOS and Impeller only. Text gamma, the luminance rule and `toImageSync`
  are unverified on Android, iOS, Windows, Linux and the web.
- Sprites are sampled nearest at the device pixel ratio: under a scaling
  transform text looks blockier than on the paragraph path.
- Narrow against wide sprites, sprites on different pages, and a space's
  underline are not kept in left-to-right order; only ink overhanging onto a
  differently coloured neighbour can show it.
- At most 8192 sprites an atlas, about 50 MB of texture at DPR 2 when full;
  past that it starts over. Real output uses a few hundred.

## CJK glyphs laid out together — 2026-11-21

*Glyph atlas, opt-in* left `cjk-zipf` 5x behind Ghostty with the atlas on.
Where that goes, in the example app (macOS, M1 Pro, Impeller):

- **First sight, not steady state.** A glyph is laid out once, when it is
  first drawn. Ten passes of `cjk-zipf` in one process, `flutter_pty2` 3.x:
  the atlas went from 30 to 67.5 MiB/s and its frame build from 18 to 0.7 ms
  as the glyphs on screen stopped being new; without a view, 78 MiB/s
  throughout. (Stock levels off at 40 MiB/s and 7 ms a frame; a 16384-entry
  paragraph cache gave 43-45, so its plateau is not the cache size.) The
  payloads are worst cases: `cjk-zipf` holds 5179 distinct glyphs, and
  `cjk-real`, despite its name, is uniform over all 20992 of the unified Han
  block, so that nearly every glyph a frame draws is new.
- **A CJK glyph costs 80 us to lay out**, against 25-29 for a Latin letter
  (a scratch release app timing `ParagraphBuilder` + `layout`), and the same
  again the second time: nothing is cached per glyph. About 20 us of it is
  the 28-family fallback list, the rest finding the system font and shaping.
- **Many to a paragraph is cheaper**, 12-15 us a glyph sixteen or more on
  one line, **but not always exact**: a paragraph tries the fonts it has
  already resolved first. A full stop after kana takes the kana's font where
  alone it takes PingFang (13.0 against 13.27 px wide), and Han after Hangul
  takes the Hangul font's Hanja. Han only (U+4E00-9FFF and U+3400-4DBF, 27584
  glyphs) and Hangul syllables only (11172) came out of such paragraphs with
  the advance, baseline and line height each has alone; kana and CJK
  punctuation did not, nor did a blank line or a space between glyphs stop
  the carry-over.

So the atlas lays a line's new Han, and separately its new Hangul, out
together: when one misses, the rest of the line and the lines painted after
it (`paintLineForegrounds(followingLines:)`) are searched for new glyphs of
the same kind, shaping styles and luminance band, up to 64. They go on one
line with a letter spacing of four wide cells, so that no neighbour reaches
into a sprite, and each sprite is cut out of that paragraph, shifted back by
its glyph's offset. The line starts with a common glyph of the kind (一 or
가), so that the font tried first is the one such glyphs get alone rather
than one a rare leading glyph found; with or without it, 202 lines led by
rare Han (U+9FA6-9FFF, the ends of extension A) and rare Hangul matched their
glyphs alone pixel for pixel. Decorated glyphs (underline, strikethrough,
overline, an active hyperlink) are laid out alone, because a decoration runs
on through the spacing. A line whose glyphs do not all have the anchor's
tight box - a font of other metrics would move every glyph's baseline - is
not used and its glyphs are laid out alone until the atlas starts over; none
was seen. Nor is a line laid out together when the atlas has no room left
for it.

Two layouts were tried first and dropped. One glyph per paragraph line, a
blank line between, cost 23-27 us a glyph whatever the batch size - a line
costs about 8-10 us - and needed whole-pixel shifts that a fractional device
pixel ratio still rasterised apart. Placeholders between glyphs on one line
cost 61-70 us a glyph.

**Pixels.** In the scratch app, the shipped construction - 一 or 가, then up
to 64 glyphs on one line spaced 62.6 px apart - over every glyph of the two
kinds in shuffled order (27584 Han, 11172 Hangul): advance, tight box,
baseline and height as each has alone, and 12644 of them, bold and italic
among them, identical pixel for pixel at device pixel ratios 2 and 3, at
every position in the line. Earlier, shorter lines matched at 1, 1.25 and 1.5
and font sizes 11-17.3. In the
example app, `shot_diff.py` against the atlas without batching: `zcjk`,
`wide`, `sgr`, plain, vim, `order` and two decorated screens identical; the
new `screens/cjkmix` - Han, extension A, Hangul, kana and punctuation in eight
styles and 255 colours - identical at DPR 1 and 32-39 pixels off by 1 level
at DPR 2 - not explained by the layout, which matched in the scratch app.
Against stock, the atlas's usual few levels.

**Frames** (`flutter_pty2` 1.0.0, paced, two rounds; median build ms; the build
before the anchor and the review fixes): `cjk-real` 37.8 → 10.6, `cjk-zipf`
14.6 → 4.1; stock 37.9 and 15.7.

**End to end** (`flutter_pty2` 3.x, frames drawn; the atlas without batching,
with this, the same build without a view, stock and Ghostty 1.4.0, five
interleaved rounds, MiB/s). Each process runs `cjk-zipf` first and `cjk-real`
second, so both rows are mostly first sight of their glyphs; that is why
"before" reads 4.90x here and 5.17-5.61x in *Glyph atlas, opt-in*, where
`cjk-zipf` ran later:

| payload | Ghostty | stock | atlas before | atlas | no view | gap before | gap after |
|---|---|---|---|---|---|---|---|
| cjk-zipf | 145.2 | 29.7 | 29.6 | 51.3 | 71.3 | 4.90x | 2.83x |
| cjk-real | 169.1 | 17.1 | 16.8 | 50.1 | 70.0 | 10.09x | 3.38x |
| unicode | 102.7 | 42.3 | 42.6 | 42.6 | 48.8 | 2.41x | 2.41x |
| truecolor | 114.8 | 19.9 | 92.4 | 91.7 | 115.1 | 1.24x | 1.25x |
| ascii | 162.9 | 77.9 | 93.9 | 92.9 | 109.1 | 1.73x | 1.75x |

With the atlas, drawing now costs `cjk-zipf` 5.2 ns/B and `cjk-real` 5.4 over
no view, from 19-45. The one-glyph-a-line layout reached 36.4 and 24.3 MiB/s
in the same run; searching only the rest of the line (an earlier run), 34.2
and 24.2. Stock is unchanged: the
paragraph path still lays out one glyph a paragraph.

**Accepted on.** Tests 1155: sprites cut from a shared paragraph against the
same glyphs alone, in the test font's distinct p and É (a build that ignores
the shift fails it); Han and Hangul painted with the atlas against stock, with
the count of sprites cut from shared paragraphs, across a following line, and
underlined glyphs left alone (a build that batches them fails it); room and
the solo marks cleared when the atlas starts over. A review found the full
atlas and the rejected line repeating their work for the rest of a line;
both fixed.

**Limits.** macOS only; which glyphs may share a paragraph depends on the
system's fallback fonts, and the two kinds were checked on this machine's.
Kana, CJK punctuation, fullwidth forms and decorated glyphs are laid out
alone. Scratch tools: `olcumler/faz2c/` in the plan folder keeps the timing
app's last source and its outputs.

## SGR-dense output: ASCII and decorations laid out together — 2026-11-21

With the atlas, `sgr` was the widest gap left (2.2-2.3x, drawing 11 ns/B over
no view). It is first sight again: random colour on random bold, italic and
underline gives about 6000 keys (94 glyphs, 8 luminance bands, 8 style
combinations), and eight passes in one process take the atlas from 38.5 to
73-76 MiB/s, its first-pass frame build from 7.5 to 0.7 ms; without a view,
76 then 87-89.

Three steps, each measured end to end:

1. **ASCII laid out together.** Printable ASCII is all in the terminal's own
   font, so it shares a paragraph like Han: a letter costs 16-34 us alone and
   1-2 us on a letter-spaced line, rasterising identically (scratch app, every
   glyph, DPR 1, 1.5, 2). Half of the keys are decorated, though, and were
   still laid out alone. `sgr` 37.6 → 41.2 MiB/s.
2. **Decorations from a reference glyph.** A decoration spans the advance,
   whatever the glyph, and every ASCII glyph has the same advance. So a
   decorated group is laid out without its decorations, and each sprite is
   drawn with the decorations of one glyph laid out alone in transparent ink.
   Every printable ASCII glyph, and Han and Hangul of the reference's
   advance, came out identical in pixels to the glyph laid out decorated, in
   single, double, through and over lines, bold and italic, at DPR 1, 1.5, 2
   and 3; a CJK glyph of another advance (51 of 400 Han sampled, 35 of 200
   Hangul) is laid out alone. A style run per glyph with undecorated spaces
   between was exact too but cost 15 us a glyph. `sgr` → 44.5 MiB/s.
3. **One scan for every group.** Each group's first miss searched the rest of
   the screen for its own company, computing every cell's key - about 64
   searches a frame on `sgr`, against about one on CJK prose. One search now
   collects every new key of every kind and group, up to 1024, and lays each
   group out in lines of up to 64; a key it has seen starts no search of its
   own until the atlas starts over. `sgr` → 53.7 MiB/s, first-pass frame
   build summed over the pass 216 → 84 ms.

**End to end** (`flutter_pty2` 3.x, frames drawn, five interleaved rounds,
MiB/s; "before" is the atlas of *CJK glyphs laid out together*; each process
runs `sgr` first):

| payload | Ghostty | stock | atlas before | atlas | no view | gap before | gap after |
|---|---|---|---|---|---|---|---|
| sgr | 89.1 | 17.3 | 38.3 | 53.7 | 79.5 | 2.33x | 1.66x |
| truecolor | 108.3 | 21.0 | 97.3 | 101.2 | 117.0 | 1.11x | 1.07x |
| ascii | 131.4 | 78.0 | 92.2 | 93.5 | 108.5 | 1.43x | 1.41x |
| cursor | 100.2 | 68.8 | 82.5 | 82.8 | 89.2 | 1.21x | 1.21x |
| cjk-zipf | 153.0 | 27.6 | 55.9 | 57.3 | 79.5 | 2.74x | 2.67x |

Drawing now costs `sgr` 5.8 ns/B over no view, from 11. The first pass
still builds 84 ms of frames against 16 warm: a search and the glyphs alone
in their group, about 1-2 ms a frame.

**Pixels.** `shot_diff.py` against the atlas before: every screen identical
but `sgr` (1-2 pixels off by 1 level) and `cjkmix` at DPR 2 (39-64 pixels
off by 1). Against stock, the atlas's usual few levels.

**Accepted on.** Tests 1157: ASCII in four styles, underlined among them,
painted with the atlas against stock, with the count of sprites cut from
shared paragraphs (a build that takes the wrong box, or keeps the
decorations in the shared line, fails it; one that drops the reference's
decorations fails the Han test); a hovered link of Han and ASCII beside
plain Hangul and ASCII of the same band. A review found the search filing
groups under an id that a hovered link's style bit carried into the kind,
so that link and plain glyphs of two kinds could share a line and swap
underlines; the id is now group times four plus kind, and the hovered-link
test fails the old one.

## The write path, token by token — 2026-11-21

The atlas work left the app's gap to Ghostty where it was without a view:
parsing and the buffer. A budget at the atlas commit, headless,
`write_budget_probe`, ns per byte:

| payload | decode | parser | full | grapheme mode off | full, bytes in |
|---|---|---|---|---|---|
| ascii | 0.77 | 1.39 | 7.68 | 7.00 | 7.37 |
| sgr | 0.76 | 5.72 | 10.01 | 9.59 | 9.93 |
| cursor | 0.90 | 5.58 | 9.62 | 9.59 | 9.93 |
| unicode | 3.77 | 4.72 | 14.9 | 13.9 | 17.7 |
| cjk-real | 2.23 | 3.53 | 10.4 | 10.1 | 12.1 |
| emoji | 3.07 | 6.76 | 52.8 | 27.6 | 55.1 |

The `parser` column of the wide payloads had been wrong since *Wide
characters in text runs*: `NoopEscapeHandler` did not take mixed-width runs,
so the parser sent every wide character down the per-character path. The
generator now adds `MixedWidthTextHandler`; the unicode parser column went
from 6.2 to 4.7 ns/B, CJK from 5.0 to 3.5.

A toy core - bytes in, local variables, no width, wrap, grapheme clustering or
scrollback - runs `ascii` at 2.3, `sgr` at 4.1 and `cursor` at 3.6 ns/B. It is
no ceiling for a real terminal, but it says where the time goes: per-token
fixed costs and per-byte field updates, not the language. Seven levers were
built apart, each checked by the tests and both oracles, and measured
together against the atlas commit; five went in.

**One scan of the head block.** `_process` took every token on its own: its
five state flags, an interface type test, three or four `ByteConsumer` calls
that each stepped past a consumed block, and for a CSI a `consume()` for the
ESC before its one-pass scan. `_scanHeadBlock` now takes the tokens most
output is made of - single-cell runs, C0 controls, the common CSI and
characters one at a time - one after another from the head block through a
local index, committing each to the queue right before it is dispatched,
since `tokenBegin` and `capturedToken` may be read then. Anything else - an
ESC that ends the block or starts something other than the common CSI, C1,
text without a text handler - goes back to `_process` as before. A handler
that writes to the parser again moves the head block on; the scan sees that
and returns.

**Per run and per line.** The text handler is resolved in the constructor.
`writeText` asks the clipboard capture whether it is active before calling
it. `writeAscii` reads the cursor style and the right limit once. The
circular buffer finds a slot by a conditional subtract instead of `%`.
Margins are no longer `late`; CR, wrap and index take shortcuts when no
margin or mode is in the way; `clamp` became comparisons. A line's anchor
list is made the first time an anchor is.

**The narrow prefix of a mixed run.** A run of narrow text that a wide
character carries on - `abc中文` - was written as two runs and a per-character
token in between. It now goes in one mixed-width run. Below U+3000 nothing
carries a run on, so ASCII, SGR-dense and cursor-addressed output pay one
comparison a run for it.

**Combining characters on the emoji path.** Most of what was left of emoji
was not the grapheme decision but the combining-character map: a
`removeWhere` scan per run write, a map remove per `setCell`, a list per
ZWJ join. Writers now skip the map when the cells they write lie above every
key in it, which holds because a line's keys never outlive its used length;
recycling a line's storage now clears its maps so that it holds there too.

Left out:
- Direct calls for LF, CR, BS and HT instead of the handler table. On their
  own they made emoji 2.3 ns/B slower; moved into the scan, they cost sgr,
  truecolor and emoji 0.3-0.9 ns/B and gave ascii, unicode and cjk-real
  0.07-0.15, within noise. The cause in the generated code was not found.
- A decoder that copies ASCII stretches of mixed chunks faster. No payload
  moved.
- A two-word cell: 8 bytes instead of 16, colours not stored, so a ceiling.
  It is still the largest lever in the core - ascii −1.7, cjk-real −1.2,
  unicode −0.9, sgr −0.6 ns/B with bytes in - and needs a style table and a
  major version.

Headless, `write_budget_probe`, the atlas commit against this change, five
interleaved passes, ns per byte (all ranges disjoint unless marked):

| payload | before, bytes in | after | Δ | before, full | Δ | parser Δ |
|---|---|---|---|---|---|---|
| ascii | 7.28 | 6.64 | −0.64 | 7.55 | −0.63 | −0.23 |
| ascii-utf8 | 8.53 | 7.75 | −0.78 | 7.67 | −0.64 | −0.23 |
| sgr | 9.97 | 7.79 | −2.18 | 9.80 | −2.16 | −1.54 |
| truecolor | 7.79 | 6.09 | −1.70 | 7.46 | −1.70 | −1.39 |
| cursor | 9.97 | 7.27 | −2.70 | 9.70 | −2.65 | −1.89 |
| unicode | 17.81 | 16.14 | −1.67 | 15.01 | −1.59 | −0.45 |
| cjk-real | 12.08 | 10.98 | −1.10 | 10.63 | −0.97 | −0.19 |
| emoji | 55.23 | 44.21 | −11.02 | 52.54 | −11.01 | −0.70 |
| combining | 70.59 | 59.29 | −11.30 | 66.82 | −11.31 | −1.95 |
| box | 6.56 | 6.15 | −0.41 | 4.49 | −0.48 | −0.23 |
| latin-ext | 8.21 | 7.39 | −0.82 | 5.72 | −0.64 | −0.35 |
| cyrillic | 8.22 | 7.59 | −0.63 (ranges touch) | 5.97 | −0.84 | −0.34 |

In the app (`flutter_pty2` 3.x, atlas on, view on, real PTY, 100x37), the
atlas commit's build, this change's build and Ghostty interleaved, five rounds,
medians, MiB/s; "without view" is this change with `XB_NOVIEW`:

| payload | before | after | without view | Ghostty | gap before | gap after |
|---|---|---|---|---|---|---|
| sgr | 54.6 | 63.0 | 92.3 | 86.8 | 1.59x | 1.38x |
| truecolor | 102.3 | 121.5 | 139.8 | 107.5 | 1.05x | 0.88x |
| ascii | 92.3 | 101.8 | 118.6 | 138.7 | 1.50x | 1.36x |
| cursor | 82.7 | 107.7 | 121.4 | 97.8 | 1.18x | 0.91x |
| unicode | 40.8 | 44.3 | 52.6 | 105.6 | 2.59x | 2.38x |
| cjk-zipf | 59.3 | 64.7 | 87.1 | 145.8 | 2.46x | 2.25x |

`truecolor` and `cursor` are level with Ghostty or ahead of it in this run -
by medians; `cursor`'s rounds overlap Ghostty's, and Ghostty moves 15-25%
from run to run. Before and after are apart in every round. Without a view
`sgr` is level with Ghostty too: what it still lacks is drawing.

**Accepted on.** Tests 1162. Among the new ones, a token-per-character check
through `TerminalDebugger`, a DECSLRM wrap from beyond the right margin,
inserts into a full circular buffer and a recycled line that held a combining
character each fail on the final tree with their fix taken out; a test of
narrow text taken into a mixed run was checked the same way on its own patch.
`terminal_state_dump.dart` (59 files, eleven splits) and `grapheme_grid_dump`
(356 files; default, grapheme mode off, 13 columns) are identical to the atlas
commit, and so is the state oracle over 200 generated files that mix text,
wide characters and C0 controls with scroll regions, left and right margins,
origin mode, autowrap off, reverse wrap, insert mode, the alternate screen,
tab stops, REP, hyperlinks and grapheme mode toggled (2200 digests). The
review also fed 180 files under 10-12 splits with handlers
writing back into the terminal - `write` asserts against that, release builds
allow it - and found the state identical. It found the recycled-line case
above and one difference it left in: after `write` has thrown - the only
trigger found, before and after, is a lone surrogate passed to
`write(String)` - a
narrow prefix and the mixed run it carried on are lost together, where before
the mixed run was replayed by the next write.

## Wide text in the buffer — 2026-11-21

After *The write path, token by token* the parser was no longer where wide
text spent its time. Taking the decode out of `writeBytes` entirely - `full`
against `full-bytes` - would save unicode 2.7 and cjk-real 1.3 ns/B, so a
parser reading bytes could at best close a third of what is left; the buffer
and terminal behind the parser took 9.1 and 6.3. A CPU profile of the example
app in profile mode, writing 16 MiB through `Terminal.write`, put the rest
in three places (shares of all samples, the harness's own work included):

| | unicode | cjk-real |
|---|---|---|
| `isSingleCellPrintable` + `isWideRunUnit` | 23.6% | 21.7% |
| `BufferLine.takeStorage` | 6.9% | 10.5% |
| `Buffer.writeMixedWidth` + `BufferLine.setMixedWidthCells` | 12.8% | 9.6% |

and on emoji, the combining-character work: string concatenation, map
lookups and `Runes.last` on each code point a cluster takes.

**A table for the run classes.** Both predicates were chains of range
comparisons - a Han character passed thirteen before `isSingleCellPrintable`
said no - and a code unit of a wide run was classified three or four times on
its way in. A 64 KiB `Uint8List` of classes, built on first use from the
range functions, which stay the definition, now answers both with one load;
printable ASCII keeps its two comparisons in front of it. The parser's scan,
`consumeTextRunInHead` and the mixed-width writers read it through a local.

**Clearing recycled storage.** `takeStorage` cleared the used words of an
evicted line one by one before handing the store to a new line. It now copies
from a shared zero list, 2048 words at a time. Every payload that fills the
scrollback gains, ASCII most, since its lines are the most numerous.

**The mixed-width writers** read the cursor style and the right margin once
per call and check for a surrogate in line. Leaning on the parser having
classified the run - a unit below U+3000 is narrow, one above it wide - was
worth another 0.6 ns/B on unicode, but a direct call to `writeMixedWidthText`
with anything else in the run would have been stored differently than before,
so they read the table.

**The emoji join path** reuses the line and combining string that the join
check has just read instead of looking both up again, appends ZWJ and the
variation selectors as constant strings, and reads a cluster's last code
point without iterating its runes. An identity map for the combining
characters gave emoji another 1.1 and combining 2.2 ns/B, but cost sgr,
cursor and truecolor 0.1-0.3 ns/B in every build that had it, for no reason
found in the code; it is left out.

Headless, `write_budget_probe`, the previous commit against this change,
five interleaved passes, ns per byte, all ranges apart unless marked:

| payload | before, bytes in | Δ | before, full | Δ | parser Δ |
|---|---|---|---|---|---|
| unicode | 16.17 | −4.83 | 13.39 | −4.91 | −2.31 |
| cjk-real | 11.00 | −4.63 | 9.58 | −4.92 | −2.41 |
| emoji | 44.19 | −5.48 | 41.45 | −5.53 | −0.71 |
| combining | 59.48 | −6.04 | 55.58 | −5.91 | −0.47 |
| ascii | 6.65 | −1.70 | 6.80 | −1.66 | −0.01 |
| ascii-utf8 | 7.72 | −1.66 | 6.99 | −1.74 | −0.03 |
| latin-ext | 7.33 | −0.94 | 4.99 | −1.02 | −0.03 |
| cyrillic | 7.43 | −0.97 | 5.19 | −1.22 | −0.17 |
| box | 5.98 | −1.09 | 3.99 | −1.18 | −0.57 |
| sgr | 7.76 | −0.56 | 7.63 | −0.53 | −0.01 (not apart) |
| cursor | 7.29 | +0.01 (not apart) | 7.06 | +0.01 (not apart) | −0.01 (not apart) |
| truecolor | 6.08 | −0.09 (not apart) | 5.79 | −0.08 (not apart) | +0.01 (not apart) |

In the app (`flutter_pty2` 3.x, atlas on, view on, real PTY, 100x37), the
previous commit's build, this change's build and Ghostty interleaved, five
rounds, medians, MiB/s; "without view" is this change with `XB_NOVIEW`:

| payload | before | after | without view | Ghostty | gap before | gap after |
|---|---|---|---|---|---|---|
| unicode | 44.7 | 58.0 | 73.2 | 112.3 | 2.51x | 1.93x |
| cjk-zipf | 64.3 | 94.0 | 129.8 | 142.5 | 2.21x | 1.51x |
| emoji | 19.6 | 22.1 | 23.0 | 82.9 | 4.22x | 3.75x |
| ascii | 101.1 | 124.0 | 150.8 | 134.1 | 1.33x | 1.08x |
| sgr | 62.6 | 65.9 | 96.9 | 87.7 | 1.40x | 1.33x |
| truecolor | 120.7 | 116.5 | 133.7 | 106.5 | 0.88x | 0.91x |
| cursor | 106.5 | 105.8 | 120.9 | 98.7 | 0.93x | 0.93x |

Before and after are apart in every round for unicode, CJK, emoji and ascii;
sgr and truecolor overlap. `cursor` came out 0.7% slower with the rounds
apart, a change the headless run does not show; CSI-dense payloads moved by
that much with unrelated changes during this work.

**Accepted on.** Tests 1170, among them the table against the range
functions over every BMP code unit, every run character written through a
mixed run against `writeChar`, recycled stores up to 3000 columns coming back
cleared, and the ZWJ, skin-tone and VS16 joins through the new path. The state
oracle over the 59-file corpus and the 200 generated mode-heavy files, eleven
splits each, and the grid oracle in three configurations are identical to
the previous commit. A review with independent verification found the
direct-call difference above, now gone, and two crashes on lone surrogates
that the previous commit has as well.

What is left: `recycleThresholdCells` was set while clearing was word by word,
so recycling now likely pays off below 700 000 cells; the identity map; and
lone surrogates passed to `write(String)` still throw from grapheme
segmentation.

## Adding a workload

Workloads are lists of per-frame strings built by a `_*Frames` function and
registered in `_run()`. Pass `setup:` for screen content that should be written
once before measurement rather than counted as per-frame work, and
`enterAltScreen: true` for anything that should not touch scrollback. Keep
generators deterministic — no clocks, no randomness without a fixed seed —
or the numbers stop being comparable between runs.
