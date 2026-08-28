// Does recycling a scrollback line ever beat allocating a fresh one?
//
//   dart compile exe script/line_reuse_probe.dart -o /tmp/probe && /tmp/probe
//
// Phase 5 rejected line pooling because zeroing a recycled line with
// `fillRange` cost about twice what allocating a replacement did, and offered
// an explanation: the VM hands out typed data from pages that are already
// zero, so allocation does not pay for the zeroing at all. Phase 5.1 doubted
// that explanation on the basis of a wrong line size. This probe settles it
// before anything is built, because whether a bounded clear can pay depends
// entirely on which explanation is true.
//
// A `BufferLine` at 170 columns is `Uint32List(192 * 4)` - 3072 bytes. Both
// scenarios keep the same number of lines alive, so the only difference
// between them is fresh-versus-recycled.
//
// The answer, on an M-series macOS, per 3072-byte line:
//
//   allocate            92 ns   = 0.12 ns/word
//   indexed store loop   -      = 0.475 ns/word
//   fillRange            -      = 1.6 ns/word
//
// Allocating is four times cheaper per word than the cheapest thing that
// actually writes the words, which means allocation is not writing them.
// Phase 5's explanation was right. A bounded clear therefore only pays when
// the span it skips is most of the line, and the table below shows that is
// not where real output sits: pooling wins at full width, where there is
// nothing left to clear, and loses across the middle widths.
//
// The second finding has no use here but is worth knowing: `fillRange` costs
// 3.4x what an indexed store loop costs, so it is not lowering to a memset.
// `BufferLine.eraseRange` already clears cell by cell, and the only other
// `fillRange` calls in `lib/` are one-time table setup.

import 'dart:typed_data';

const _cellSize = 4;
const _capacityCells = 192;
const _words = _capacityCells * _cellSize;

const _iterations = 400000;

int _sink = 0;

void main() {
  print('line = Uint32List($_words) = ${_words * 4} bytes, '
      '$_iterations iterations per cell');
  print('');
  print('written  depth   alloc  fill-all  fill-written  loop-written  '
      'loop-tail   verdict');

  for (final depth in [8, 64, 512]) {
    for (final written in [30, 60, 120, 192]) {
      final alloc = _bench(() => _allocRun(depth, written));
      final fillAll = _bench(() => _poolRun(depth, written, _words));
      final fillWritten =
          _bench(() => _poolRun(depth, written, written * _cellSize));
      final loopWritten = _bench(() => _loopRun(depth, written, false));
      final loopTail = _bench(() => _loopRun(depth, written, true));

      final best = loopTail < loopWritten ? loopTail : loopWritten;
      final verdict = switch (best < alloc) {
        true => 'pool wins by '
            '${((alloc / best - 1) * 100).toStringAsFixed(0)}%',
        false => 'alloc wins by '
            '${((best / alloc - 1) * 100).toStringAsFixed(0)}%',
      };

      print('${written.toString().padLeft(7)}'
          '${depth.toString().padLeft(7)}'
          '${alloc.toStringAsFixed(0).padLeft(8)}'
          '${fillAll.toStringAsFixed(0).padLeft(10)}'
          '${fillWritten.toStringAsFixed(0).padLeft(14)}'
          '${loopWritten.toStringAsFixed(0).padLeft(14)}'
          '${loopTail.toStringAsFixed(0).padLeft(11)}'
          '   $verdict');
    }
  }

  print('');
  print('ns per line, lower is better. sink=$_sink');
  print('alloc         = fresh Uint32List per line, old one becomes garbage');
  print('fill-all      = recycle from a ring, fillRange the whole capacity');
  print('fill-written  = recycle from a ring, fillRange only the written span');
  print('loop-written  = same span, cleared with an indexed store loop');
  print('loop-tail     = store loop over the old high-water mark only, since');
  print('                the write itself already covers what precedes it');
}

/// Scrolling as it works today: every line that falls off is garbage and its
/// replacement is a fresh allocation. [depth] lines stay live, which is what
/// keeps the comparison against the pooled runs fair.
void _allocRun(int depth, int written) {
  final ring = List<Uint32List?>.filled(depth, null);
  for (var i = 0; i < _iterations; i++) {
    final line = Uint32List(_words);
    _write(line, written);
    ring[i % depth] = line;
  }
  _sink ^= ring[0]![0];
}

/// Scrolling with a pool: the line that falls off comes back, cleared over
/// [clearWords] words before it is written again.
void _poolRun(int depth, int written, int clearWords) {
  final ring = List.generate(depth, (_) => Uint32List(_words));
  for (var i = 0; i < _iterations; i++) {
    final line = ring[i % depth];
    line.fillRange(0, clearWords, 0);
    _write(line, written);
  }
  _sink ^= ring[0][0];
}

/// The two clears worth building, both with an indexed store loop rather than
/// [Uint32List.fillRange].
///
/// When [tailOnly], only the span between the new write extent and the
/// previous high-water mark is cleared - the write itself covers everything
/// before it, so zeroing that first would be work done twice. The previous
/// extent rotates so this does not degenerate into a steady state where the
/// tail is always empty.
void _loopRun(int depth, int written, bool tailOnly) {
  final ring = List.generate(depth, (_) => Uint32List(_words));
  final marks = List.filled(depth, _capacityCells);

  for (var i = 0; i < _iterations; i++) {
    final slot = i % depth;
    final line = ring[slot];
    final previous = marks[slot];

    final from = switch (tailOnly) {
      true => written * _cellSize,
      false => 0,
    };
    final to = switch (tailOnly) {
      true => previous * _cellSize,
      false => written * _cellSize,
    };
    for (var word = from; word < to; word++) {
      line[word] = 0;
    }

    _write(line, written);
    marks[slot] = switch (i & 3) {
      0 => _capacityCells,
      1 => written,
      2 => (written * 3) ~/ 2 > _capacityCells
          ? _capacityCells
          : (written * 3) ~/ 2,
      _ => written,
    };
  }
  _sink ^= ring[0][0];
}

/// Stands in for `BufferLine.setAsciiCells`: four words per cell, over the
/// cells the line actually holds text in.
void _write(Uint32List line, int cells) {
  for (var cell = 0; cell < cells; cell++) {
    final offset = cell * _cellSize;
    line[offset] = 0x00ffffff;
    line[offset + 1] = 0xff000000;
    line[offset + 2] = 0;
    line[offset + 3] = 0x41 | (1 << 21);
  }
}

/// Median of five, so one scheduling hiccup cannot decide a row.
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
