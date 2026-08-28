// Does trimming a line as it leaves the viewport pay, or does it have to be
// born small?
//
//   dart compile exe script/trim_variant_probe.dart -o /tmp/p && /tmp/p
//
// `scrollback_cost_probe.dart` showed the scrollback penalty is the promotion
// copy of a line's backing store, and that a right-sized store is worth up to
// 3x. That probe measured lines that were *born* right-sized. Trimming is not
// that: the line lives in the viewport at full capacity and only gets a
// smaller store when it drops into scrollback, so it spends an allocation and
// a copy of the small size to save promoting the large one - and those two are
// the same order of magnitude.
//
// They are, and trimming loses. Across every depth and width measured it lands
// 9-30% behind doing nothing, while being born right-sized wins 1.2-3.0x. The
// saving is in never allocating the large store, not in giving it back.
//
// Recorded because trimming is the obvious form of the idea and the one with
// the narrow blast radius - it does not touch the write path, and the render
// path already drives off `line.length`. It is worth knowing it was measured
// and does not work before anyone reaches for it again.

import 'dart:typed_data';

const _cellSize = 4;
const _viewportCells = 192;
const _viewportLines = 50;
const _iterations = 200000;

int _sink = 0;

void main() {
  print('viewport $_viewportLines lines at $_viewportCells cells '
      '(${_viewportCells * _cellSize * 4} bytes)');
  print('');
  print('  depth  written   capacity     today      trim      born   '
      'trim vs today');

  for (final depth in [1000, 4000, 10000]) {
    for (final (written, capacity) in [
      (30, 64),
      (60, 96),
      (95, 96),
      (120, 128)
    ]) {
      final today = _bench(() => _run(depth, written, _viewportCells, false));
      final trim = _bench(() => _run(depth, written, capacity, true));
      final born = _bench(() => _run(depth, written, capacity, false));

      final delta = (today / trim - 1) * 100;
      final verdict = switch (delta > 0) {
        true => 'trim wins ${delta.toStringAsFixed(0)}%',
        false => 'trim loses ${(-delta).toStringAsFixed(0)}%',
      };

      print('${depth.toString().padLeft(7)}'
          '${written.toString().padLeft(9)}'
          '${capacity.toString().padLeft(11)}'
          '${today.toStringAsFixed(0).padLeft(10)}'
          '${trim.toStringAsFixed(0).padLeft(10)}'
          '${born.toStringAsFixed(0).padLeft(10)}'
          '   $verdict');
    }
  }

  print('');
  print('ns per line. sink=$_sink');
}

/// One scroll step. A line is allocated at viewport capacity and written to,
/// then travels through a [_viewportLines]-deep viewport before landing in
/// the scrollback ring. When [trim], it is copied into a store of
/// [scrollbackCapacity] cells on the way; otherwise it is allocated at
/// [scrollbackCapacity] to begin with and no copy happens.
void _run(int depth, int written, int scrollbackCapacity, bool trim) {
  final viewport = List<Uint32List?>.filled(_viewportLines, null);
  final scrollback = List<Uint32List?>.filled(depth, null);

  final bornCapacity = trim ? _viewportCells : scrollbackCapacity;

  for (var i = 0; i < _iterations; i++) {
    final line = Uint32List(bornCapacity * _cellSize);
    final cells = written < bornCapacity ? written : bornCapacity;
    for (var cell = 0; cell < cells; cell++) {
      final offset = cell * _cellSize;
      line[offset] = 0x00ffffff;
      line[offset + 1] = 0xff000000;
      line[offset + 2] = 0;
      line[offset + 3] = 0x41 | (1 << 21);
    }

    final slot = i % _viewportLines;
    final leaving = viewport[slot];
    viewport[slot] = line;

    if (leaving != null) {
      scrollback[i % depth] = switch (trim) {
        true => _trimmed(leaving, scrollbackCapacity),
        false => leaving,
      };
    }
  }
  _sink ^= scrollback[0]?[0] ?? 0;
}

/// What `BufferLine.trimToContent` would do: a right-sized store and a copy
/// of the prefix that holds content.
Uint32List _trimmed(Uint32List line, int capacityCells) {
  final words = capacityCells * _cellSize;
  final trimmed = Uint32List(words);
  trimmed.setRange(0, words, line);
  return trimmed;
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
