// Prints the complete buffer state a file leaves behind, so two builds of the
// write path can be compared cell for cell.
//
//   dart compile exe script/grapheme_grid_dump.dart -o /tmp/dump
//   /tmp/dump [--cols N] [--rows N] [--no-graph] [--full] <files...>
//
// Each file is cut into 1021-byte chunks - an odd size, so chunk boundaries
// fall inside UTF-8 sequences and grapheme clusters - decoded with a chunked
// `Utf8Decoder` and fed to a fresh `Terminal.write`. `--no-graph` turns DEC
// mode 2027 off first, as `bin/parse_bench.dart` does for its no-grapheme
// column. For every line (scrollback included) the dump lists the wrap flag
// and every cell's code point, width and combining code points, then the
// cursor. One line per file is printed with an FNV-1a digest of that dump;
// `--full` prints the dump itself as well. Scrollback is sized so that no line
// is ever evicted; a file that fills it is reported, not silently truncated.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xterm3/src/terminal.dart';

const _chunk = 1021;
const _maxLines = 400000;

void main(List<String> args) {
  var cols = 100, rows = 37, graph = true, full = false;
  final files = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--cols':
        cols = int.parse(args[++i]);
      case '--rows':
        rows = int.parse(args[++i]);
      case '--no-graph':
        graph = false;
      case '--full':
        full = true;
      default:
        files.add(args[i]);
    }
  }

  for (final path in files) {
    final terminal = Terminal(maxLines: _maxLines)..resize(cols, rows);
    if (!graph) terminal.write('\x1b[?2027l');
    final bytes = File(path).readAsBytesSync();
    final sink = const Utf8Decoder().startChunkedConversion(
      _WriteSink(terminal),
    );
    for (var i = 0; i < bytes.length; i += _chunk) {
      sink.add(
          Uint8List.sublistView(bytes, i, (i + _chunk).clamp(0, bytes.length)));
    }
    sink.close();

    final buffer = terminal.buffer;
    if (buffer.height >= _maxLines) {
      stderr.writeln('$path: scrollback full, lines were evicted');
      exitCode = 1;
    }
    final out = StringBuffer();
    var hash = 0xcbf29ce484222325;
    void emit(String s) {
      if (full) out.write(s);
      for (final unit in s.codeUnits) {
        hash = (hash ^ unit) * 0x100000001b3;
      }
    }

    for (var y = 0; y < buffer.height; y++) {
      final line = buffer.lines[y];
      final cells = StringBuffer(line.isWrapped ? 'w' : '-');
      for (var x = 0; x < line.length; x++) {
        cells.write(' ${line.getCodePoint(x).toRadixString(16)}'
            ':${line.getWidth(x)}');
        final combining = line.getCombiningCharacters(x);
        if (combining != null) {
          for (final rune in combining.runes) {
            cells.write('+${rune.toRadixString(16)}');
          }
        }
      }
      emit('$y $cells\n');
    }
    emit('cursor ${buffer.cursorX},${buffer.cursorY}\n');

    final name = path.split('/').last;
    stdout.writeln('$name ${hash.toRadixString(16)} lines=${buffer.height}');
    if (full) stdout.write(out);
  }
}

class _WriteSink implements Sink<String> {
  _WriteSink(this.terminal);
  final Terminal terminal;
  @override
  void add(String data) => terminal.write(data);
  @override
  void close() {}
}
