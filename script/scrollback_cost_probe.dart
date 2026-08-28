// What does holding scrollback actually cost per line?
//
//   dart compile exe script/scrollback_cost_probe.dart -o /tmp/p && /tmp/p
//
// `parse_bench`'s `scrollback` column runs the terminal with `maxLines: 0`,
// which `Buffer` widens to `max(maxLines, viewHeight)` - so the ring is still
// 50 lines, the allocation per scroll is the same, and the eviction
// bookkeeping is the same. The only thing that changes is how many lines stay
// alive: 50 instead of 10000.
//
// On `ascii` that column is worth 328 ns per line, and `line_reuse_probe`
// measured allocation on its own at 92 ns. This asks where the other 236 ns
// is, and the answer is the live set: at 30 written cells a line costs 145 ns
// with 50 alive and 546 ns with 10000 alive. That is the garbage collector
// promoting each line's 3072-byte backing store into old space, and the copy
// is proportional to the store, not to the text in it.
//
// So the lever is the size of the store. The `wN@C` columns allocate each
// line at `_calcCapacity` of the width it actually writes, which is what
// `BufferLine` would hold if it were not born at viewport width: at 10000
// deep that is 561 -> 180 ns for a 30-column line and 767 -> 590 for a
// 120-column one.
//
// Phase 5's closing line said anything aimed at the scrolling cost has to
// reduce the number of lines allocated *or their size*. This is the size half,
// and it had never been tried. See `trim_variant_probe.dart` for which form
// of it works.

import 'dart:typed_data';

const _cellSize = 4;
const _capacityCells = 192;
const _iterations = 200000;

int _sink = 0;

void main() {
  print('written = cells the line holds text in; capacity is '
      '$_capacityCells cells = ${_capacityCells * _cellSize * 4} bytes');
  print('');
  print(
      '  depth   live      w=30    w=60   w=120   w=192   w30@64  w60@96  w120@128');

  for (final depth in [50, 200, 1000, 4000, 10000]) {
    final row = StringBuffer();
    row.write(depth.toString().padLeft(7));
    row.write(
        '${(depth * _capacityCells * _cellSize * 4 / (1024 * 1024)).toStringAsFixed(0)} MB'
            .padLeft(7));
    for (final written in [30, 60, 120, 192]) {
      row.write(
        _bench(() => _run(depth, written, _capacityCells))
            .toStringAsFixed(0)
            .padLeft(8),
      );
    }
    // Same lines, allocated at what `_calcCapacity` would give for their
    // written width rather than for the viewport width. 64 is that function's
    // floor, so w=30 cannot go below it.
    for (final (written, capacity) in [(30, 64), (60, 96), (120, 128)]) {
      row.write(
        _bench(() => _run(depth, written, capacity))
            .toStringAsFixed(0)
            .padLeft(8),
      );
    }
    print(row);
  }

  print('');
  print('ns per line. sink=$_sink');
  print('w=N          = full-capacity line, N cells written, depth kept alive');
  print('wN@C         = N cells written into a line allocated at C cells,');
  print('               which is _calcCapacity(N) - what trimming would give');
}

/// One scroll step: allocate a line, write to it, keep [depth] of them alive
/// and let the oldest go - which is what `lines.push(_newEmptyLine())` does
/// against an `IndexAwareCircularBuffer` of that size.
void _run(int depth, int written, int capacityCells) {
  final ring = List<Uint32List?>.filled(depth, null);
  for (var i = 0; i < _iterations; i++) {
    final line = Uint32List(capacityCells * _cellSize);
    final cells = written < capacityCells ? written : capacityCells;
    for (var cell = 0; cell < cells; cell++) {
      final offset = cell * _cellSize;
      line[offset] = 0x00ffffff;
      line[offset + 1] = 0xff000000;
      line[offset + 2] = 0;
      line[offset + 3] = 0x41 | (1 << 21);
    }
    ring[i % depth] = line;
  }
  _sink ^= ring[0]![0];
}

double _bench(void Function() body) {
  final samples = <double>[];
  for (var run = 0; run < 5; run++) {
    final stopwatch = Stopwatch()..start();
    body();
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds * 1000 / _iterations);
  }
  samples.sort();
  return samples[2];
}
