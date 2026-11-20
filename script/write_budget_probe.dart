// Per-code-point cost of Terminal.write, by stage, on real payload files.
//
//   python3 script/term_compare/gen.py 64 <dir>
//   dart compile exe script/write_budget_probe.dart -o /tmp/wbp
//   /tmp/wbp <rounds> [--modes=full,parser] [--counts] <dir>/ascii <dir>/sgr ...
//
// Same setup as unicode_layer_probe.dart - 100x37, Terminal(maxLines: 10000),
// LF turned into CRLF as the PTY's ONLCR does, a chunked Utf8Decoder, rounds
// interleaved across payloads and modes, medians - with two differences: it
// reports ns per code point next to MiB/s, because bytes per code point differ
// by payload, and it adds the modes a budget needs:
//
//   decode    = the chunked Utf8Decoder alone, bytes -> String, 64 KiB chunks
//   decode-1k = the same at 1 KiB, what the example app's PTY delivers
//   parser    = EscapeParser + NoopEscapeHandler on the decoded strings
//   full      = Terminal.write, 10000 lines of scrollback, 64 KiB chunks
//   full-1k   = the same at 1 KiB chunks
//   scroll0   = Terminal(maxLines: 0): the ring is one screen, nothing is kept
//   no-graph  = full with DEC mode 2027 off
//   scroll0-no-graph = both of the above
//
// --counts prints, once per payload and untimed, what the budget divides by:
// code points, lines, CSI sequences by final byte, printable code points.
// Every sample is also printed as `S <payload> <mode> <seconds>` so runs of
// several binaries can be interleaved and pooled by a script. Compile it - JIT
// numbers are not comparable.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xterm3/src/core/escape/parser.dart';
import 'package:xterm3/src/terminal.dart';

import '../bin/noop_escape_handler.dart';

const _allModes = [
  'decode',
  'decode-1k',
  'parser',
  'full',
  'full-1k',
  'scroll0',
  'no-graph',
  'scroll0-no-graph',
];

int _sink = 0;

void main(List<String> args) {
  final rounds = int.parse(args.first);
  var modes = _allModes;
  var counts = false;
  final files = <String>[];
  for (final a in args.skip(1)) {
    if (a.startsWith('--modes=')) {
      modes = a.substring(8).split(',');
    } else if (a == '--counts') {
      counts = true;
    } else {
      files.add(a);
    }
  }
  final samples = <String, List<double>>{};
  final codePoints = <String, int>{};

  for (var round = 1; round <= rounds; round++) {
    for (final path in files) {
      final name = path.split('/').last;
      final file = File(path).readAsBytesSync();
      final bytes = _onlcr(file);
      final chunks64 = _split(bytes, 64 * 1024);
      final chunks1 = _split(bytes, 1024);
      final strings64 = _decode(chunks64);
      final strings1 = _decode(chunks1);
      final mib = file.length / 1024 / 1024;
      codePoints[name] ??= _codePoints(strings64);
      if (counts && round == 1) _printCounts(name, mib, strings64);

      for (final mode in modes) {
        final small = mode.endsWith('-1k');
        final chunks = small ? chunks1 : chunks64;
        final strings = small ? strings1 : strings64;
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
          case 'full' ||
                'full-1k' ||
                'scroll0' ||
                'no-graph' ||
                'scroll0-no-graph':
            final terminal =
                Terminal(maxLines: mode.startsWith('scroll0') ? 0 : 10000)
                  ..resize(100, 37);
            if (mode.endsWith('no-graph')) terminal.write('\x1b[?2027l');
            sw.start();
            for (final s in strings) {
              terminal.write(s);
            }
            sw.stop();
            _sink += terminal.buffer.height;
          default:
            throw ArgumentError('unknown mode $mode');
        }
        final seconds = sw.elapsedMicroseconds / 1e6;
        (samples['$name $mode'] ??= []).add(seconds);
        print('S $name $mode $seconds');
      }
    }
  }

  print('');
  print('medians, n=$rounds, 100x37: MiB/s | ns per code point');
  print('payload     ${modes.map((m) => m.padLeft(17)).join()}');
  for (final path in files) {
    final name = path.split('/').last;
    final mib = File(path).lengthSync() / 1024 / 1024;
    print('${name.padRight(12)}${modes.map((m) {
      final s = _median(samples['$name $m']!);
      final cell = '${(mib / s).toStringAsFixed(1)} | '
          '${(s * 1e9 / codePoints[name]!).toStringAsFixed(2)}';
      return cell.padLeft(17);
    }).join()}');
  }
  if (_sink == 42) print('');
}

int _codePoints(List<String> strings) {
  var n = 0;
  for (final s in strings) {
    for (var i = 0; i < s.length; i++) {
      final u = s.codeUnitAt(i);
      if (u < 0xdc00 || u > 0xdfff) n++;
    }
  }
  return n;
}

/// Untimed token census of the decoded input: what the parser will see.
void _printCounts(String name, double mib, List<String> strings) {
  var cps = 0, lf = 0, cr = 0, printable = 0, wideish = 0, esc = 0;
  final csiFinal = <int, int>{};
  var state = 0; // 0 ground, 1 after ESC, 2 in CSI
  for (final s in strings) {
    for (var i = 0; i < s.length; i++) {
      final u = s.codeUnitAt(i);
      if (u >= 0xdc00 && u <= 0xdfff) continue;
      cps++;
      switch (state) {
        case 1:
          state = u == 0x5b ? 2 : 0;
          continue;
        case 2:
          if (u >= 0x40 && u <= 0x7e) {
            csiFinal[u] = (csiFinal[u] ?? 0) + 1;
            state = 0;
          }
          continue;
      }
      if (u == 0x1b) {
        esc++;
        state = 1;
      } else if (u == 0x0a) {
        lf++;
      } else if (u == 0x0d) {
        cr++;
      } else if (u >= 0x20 && u != 0x7f) {
        printable++;
        if (u >= 0x1100) wideish++;
      }
    }
  }
  String per(int n) => (n / mib).toStringAsFixed(0);
  final csi = csiFinal.entries.map((e) {
    return '${String.fromCharCode(e.key)}=${per(e.value)}';
  }).join(' ');
  print('C $name bytes/MiB=${(1024 * 1024).toString()} '
      'codepoints/MiB=${per(cps)} printable/MiB=${per(printable)} '
      'ge_U+1100/MiB=${per(wideish)} LF/MiB=${per(lf)} CR/MiB=${per(cr)} '
      'ESC/MiB=${per(esc)} CSI/MiB: $csi '
      'bytes/codepoint=${(mib * 1024 * 1024 / cps).toStringAsFixed(3)}');
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
