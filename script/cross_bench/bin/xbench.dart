// Identical write-path workloads run against xterm, xterm2 and xterm3.
//
//   dart compile exe bin/xbench.dart -o /tmp/xbench
//   /tmp/xbench xterm | /tmp/xbench xterm2 | /tmp/xbench xterm3
//
// One package per process: the terminals hold tens of MB of scrollback and
// RSS is one of the numbers being reported, so they must not share a heap.

import 'dart:io';

import 'package:xterm/core.dart' as v1;
import 'package:xterm2/core.dart' as v2;
import 'package:xterm3/core.dart' as v3;

const _columns = 170;
const _rows = 50;
const _chunkSize = 8192;
const _totalBytes = 32 * 1024 * 1024;
const _scrollback = 10000;

typedef Writer = void Function(String);
typedef Resizer = void Function(int, int);

/// A terminal behind an interface the three packages can share.
class Term {
  Term(this.write, this.resize);
  final Writer write;
  final Resizer resize;
}

Term _buildTerm(String package) {
  switch (package) {
    case 'xterm':
      final t = v1.Terminal(maxLines: _scrollback)..resize(_columns, _rows);
      return Term(t.write, (c, r) => t.resize(c, r));
    case 'xterm2':
      final t = v2.Terminal(maxLines: _scrollback)..resize(_columns, _rows);
      return Term(t.write, (c, r) => t.resize(c, r));
    case 'xterm3':
      final t = v3.Terminal(maxLines: _scrollback)..resize(_columns, _rows);
      return Term(t.write, (c, r) => t.resize(c, r));
  }
  throw ArgumentError('unknown package: $package');
}

Writer _build(String package) {
  switch (package) {
    case 'xterm':
      return (v1.Terminal(maxLines: _scrollback)..resize(_columns, _rows)).write;
    case 'xterm2':
      return (v2.Terminal(maxLines: _scrollback)..resize(_columns, _rows)).write;
    case 'xterm3':
      return (v3.Terminal(maxLines: _scrollback)..resize(_columns, _rows)).write;
  }
  throw ArgumentError('unknown package: $package');
}

void main(List<String> args) {
  final package = args.isEmpty ? 'xterm3' : args.first;
  final mode = args.length > 1 ? args[1] : 'throughput';

  if (mode == 'memory') {
    _memory(package);
    return;
  }

  if (mode == 'reflow') {
    _reflow(package);
    return;
  }

  final workloads = <String, String Function(int)>{
    'ascii': _asciiChunk,
    'ascii-long-lines': _longLineChunk,
    'sgr': _sgrChunk,
    'utf8': _utf8Chunk,
    'cyrillic': _cyrillicChunk,
    'altscreen': _altScreenChunk,
  };

  for (final entry in workloads.entries) {
    final chunks = _buildChunks(entry.value);
    final mibs = _measure(chunks, () => _build(package));
    print('$package\t${entry.key}\t${mibs.toStringAsFixed(1)}');
  }
}

/// Resident set after filling the scrollback ring, minus the same process
/// before the terminal exists. Reported for the ASCII workload only; it is a
/// property of the buffer, not of the bytes.
void _memory(String package) {
  final chunks = _buildChunks(_asciiChunk);
  final before = ProcessInfo.currentRss;
  final write = _build(package);
  var bytes = 0;
  var index = 0;
  while (bytes < 24 * 1024 * 1024) {
    final chunk = chunks[index++ % chunks.length];
    write(chunk);
    bytes += chunk.length;
  }
  // Writing leaves a heap full of garbage: the chunk strings, the cells that
  // scrolled out. Dart exposes no explicit collection, so force generations
  // through by allocating and dropping, and take the low-water mark - what is
  // still resident once the collector has had its chances is what the
  // scrollback actually costs.
  var low = ProcessInfo.currentRss;
  for (var round = 0; round < 40; round++) {
    var churn = <int>[];
    for (var i = 0; i < 200000; i++) {
      churn.add(i);
    }
    churn = <int>[];
    final rss = ProcessInfo.currentRss;
    if (rss < low) low = rss;
  }
  final after = low;
  print('$package\trss\t${((after - before) / 1024 / 1024).toStringAsFixed(1)}');
  // Keep the terminal alive past the measurement.
  if (identityHashCode(write) == 0) print('unreachable');
}

/// Cost of a window resize once the scrollback is full: the reflow that
/// rewraps every retained line. Narrow and back, ten times, on 10000 lines.
void _reflow(String package) {
  final chunks = _buildChunks(_asciiChunk);
  final term = _buildTerm(package);
  var bytes = 0;
  var index = 0;
  while (bytes < 24 * 1024 * 1024) {
    final chunk = chunks[index++ % chunks.length];
    term.write(chunk);
    bytes += chunk.length;
  }

  term.resize(120, _rows);
  term.resize(_columns, _rows);

  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < 10; i++) {
    term.resize(80, _rows);
    term.resize(_columns, _rows);
  }
  stopwatch.stop();

  final msPerPair = stopwatch.elapsedMicroseconds / 10 / 1000;
  print('$package\treflow\t${msPerPair.toStringAsFixed(1)}');
}

double _measure(List<String> chunks, Writer Function() build) {
  final write = build();

  for (var i = 0; i < 8; i++) {
    write(chunks[i % chunks.length]);
  }

  final stopwatch = Stopwatch()..start();
  var bytes = 0;
  var index = 0;
  while (bytes < _totalBytes) {
    final chunk = chunks[index++ % chunks.length];
    write(chunk);
    bytes += chunk.length;
  }
  stopwatch.stop();

  return bytes / 1024 / 1024 / (stopwatch.elapsedMicroseconds / 1000000);
}

List<String> _buildChunks(String Function(int) generator) {
  return List.generate(16, generator, growable: false);
}

String _asciiChunk(int seed) {
  final buffer = StringBuffer();
  var line = seed * 1000;
  while (buffer.length < _chunkSize) {
    buffer.write('-rw-r--r--  1 user  staff  ${line * 7919 % 1000000} '
        'Aug  2 12:${(line % 60).toString().padLeft(2, '0')} '
        'file_${line}_with_a_reasonably_long_name.dart\r\n');
    line++;
  }
  return buffer.toString();
}

String _longLineChunk(int seed) {
  final buffer = StringBuffer();
  var word = seed * 1000;
  while (buffer.length < _chunkSize) {
    final line = StringBuffer();
    while (line.length < _columns * 4) {
      line.write('token_${word % 9973}=${word * 7919 % 100000} ');
      word++;
    }
    buffer.write(line);
    buffer.write('\r\n');
  }
  return buffer.toString();
}

String _sgrChunk(int seed) {
  final buffer = StringBuffer();
  var line = seed * 1000;
  while (buffer.length < _chunkSize) {
    for (var segment = 0; segment < 6; segment++) {
      buffer.write('\x1b[38;5;${(line * 13 + segment * 31) % 256}m');
      buffer.write('segment${segment}_of_line_$line ');
    }
    buffer.write('\x1b[0m\r\n');
    line++;
  }
  return buffer.toString();
}

String _utf8Chunk(int seed) {
  final buffer = StringBuffer();
  var line = seed * 1000;
  while (buffer.length < _chunkSize) {
    buffer.write('satır $line — ölçüm değeri ${line * 7919 % 100000} '
        'açıklama_metni_$line şüpheli\r\n');
    line++;
  }
  return buffer.toString();
}

String _cyrillicChunk(int seed) {
  final buffer = StringBuffer();
  var line = seed * 1000;
  while (buffer.length < _chunkSize) {
    buffer.write('строка $line значение измерения ${line * 7919 % 100000} '
        'описание_текста_$line подозрительно\r\n');
    line++;
  }
  return buffer.toString();
}

String _altScreenChunk(int seed) {
  final buffer = StringBuffer();
  var frame = seed * 100;
  while (buffer.length < _chunkSize) {
    for (var row = 0; row < _rows; row++) {
      buffer.write('\x1b[${row + 1};1H');
      buffer.write('\x1b[48;5;${(row * 3 + frame) % 256}m');
      final bar = (frame + row) % _columns;
      for (var column = 0; column < _columns; column++) {
        buffer.write(column < bar ? '#' : ' ');
      }
      buffer.write('\x1b[0m');
    }
    frame++;
  }
  return buffer.toString();
}
