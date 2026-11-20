// Where does the write path spend its time, per script class, on real
// payload files?
//
//   python3 script/term_compare/gen.py 64 <dir>
//   dart compile exe script/unicode_layer_probe.dart -o /tmp/ulp
//   /tmp/ulp <rounds> <dir>/ascii <dir>/unicode <dir>/cjk ...
//
// The end-to-end harness (script/term_compare/) says the example app does
// mixed `unicode` at a fifth of `ascii`. This splits the core side of that,
// with no Flutter: each file is cut into 64 KiB chunks (drive.py's write size)
// and decoded with a chunked `Utf8Decoder`, as `e2e_bench.dart`'s
// `transform(const Utf8Decoder())` does, then fed at a 100x37 grid to
//
//   decode   = the chunked Utf8Decoder alone, bytes -> String
//   parser   = EscapeParser + NoopEscapeHandler, on the decoded strings
//   full     = Terminal.write, 10000 lines of scrollback
//   no-graph = Terminal.write with DEC mode 2027 off
//   *-1k     = decode / full again with 1 KiB chunks, which is what the
//              example app's PTY stream actually delivers on macOS (measured
//              with XB_PROF in e2e_bench.dart: ~1 KiB per write call)
//
// parser/full/no-graph are timed on already-decoded strings, so decode + full
// is the core's share of one byte's trip through the app. Every LF is first
// turned into CRLF, as the PTY's ONLCR does for drive.py (it only sets
// cbreak); left as bare LF the column never resets and fast rows read ~25%
// low. MiB/s is per byte of the file as written, the unit drive.py reports. Rounds are interleaved across
// payloads and modes; medians are printed at the end. Compile it - JIT
// numbers are not comparable.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xterm3/src/core/escape/parser.dart';
import 'package:xterm3/src/terminal.dart';

import '../bin/noop_escape_handler.dart';

const _chunk = 64 * 1024;
const _modes = ['decode', 'parser', 'full', 'no-graph', 'decode-1k', 'full-1k'];

int _sink = 0;

void main(List<String> args) {
  final rounds = int.parse(args.first);
  final files = args.skip(1).toList();
  final samples = <String, List<double>>{};

  for (var round = 1; round <= rounds; round++) {
    for (final path in files) {
      final name = path.split('/').last;
      final file = File(path).readAsBytesSync();
      final bytes = _onlcr(file);
      final chunks64 = _split(bytes, _chunk), chunks1 = _split(bytes, 1024);
      final strings64 = _decode(chunks64);
      final mib = file.length / 1024 / 1024;

      for (final mode in _modes) {
        final small = mode.endsWith('-1k');
        final chunks = small ? chunks1 : chunks64;
        final strings = small ? _decode(chunks1) : strings64;
        final sw = Stopwatch();
        switch (mode) {
          case 'decode' || 'decode-1k':
            sw.start();
            _sink += _decode(chunks).length;
            sw.stop();
          case 'parser':
            final parser = EscapeParser(NoopEscapeHandler());
            sw.start();
            for (final s in strings) {
              parser.write(s);
            }
            sw.stop();
          default:
            final terminal = Terminal(maxLines: 10000)..resize(100, 37);
            if (mode == 'no-graph') terminal.write('\x1b[?2027l');
            sw.start();
            for (final s in strings) {
              terminal.write(s);
            }
            sw.stop();
            _sink += terminal.buffer.height;
        }
        final mibs = mib / (sw.elapsedMicroseconds / 1e6);
        (samples['$name $mode'] ??= []).add(mibs);
        print('round $round  ${name.padRight(10)} ${mode.padRight(9)} '
            '${mibs.toStringAsFixed(1)} MiB/s');
      }
    }
  }

  print('');
  print('medians, MiB/s, n=$rounds, 100x37, 64 KiB chunks unless -1k');
  print('payload     ${_modes.map((m) => m.padLeft(9)).join()}');
  for (final path in files) {
    final name = path.split('/').last;
    print('${name.padRight(12)}${_modes.map((m) {
      return _median(samples['$name $m']!).toStringAsFixed(1).padLeft(9);
    }).join()}');
  }
  if (_sink == 42) print('');
}

Uint8List _onlcr(Uint8List src) {
  final out = BytesBuilder(copy: false);
  var start = 0;
  for (var i = 0; i < src.length; i++) {
    if (src[i] != 0x0a) continue;
    out.add(Uint8List.sublistView(src, start, i));
    out.add(const [0x0d, 0x0a]);
    start = i + 1;
  }
  out.add(Uint8List.sublistView(src, start));
  return out.takeBytes();
}

List<Uint8List> _split(Uint8List bytes, int size) => [
      for (var i = 0; i < bytes.length; i += size)
        Uint8List.sublistView(bytes, i, (i + size).clamp(0, bytes.length)),
    ];

List<String> _decode(List<Uint8List> chunks) {
  final out = <String>[];
  final sink = const Utf8Decoder().startChunkedConversion(_ListSink(out));
  for (final c in chunks) {
    sink.add(c);
  }
  sink.close();
  return out;
}

double _median(List<double> v) {
  final s = [...v]..sort();
  return s.length.isOdd
      ? s[s.length ~/ 2]
      : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

class _ListSink implements Sink<String> {
  _ListSink(this.out);
  final List<String> out;
  @override
  void add(String data) => out.add(data);
  @override
  void close() {}
}
