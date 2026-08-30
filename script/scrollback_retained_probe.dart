// How much does a scrollback of 10000 lines actually hold on to?
//
//   dart run script/scrollback_retained_probe.dart
//
// `scrollback_cost_probe` measured what holding scrollback costs in time.
// This measures what it costs in bytes, which is the half of phase 6 that
// survived: a line's store is sized at birth to the viewport, so a 60-column
// line of output retains the same 3072 bytes as a 170-column one.
//
// Against a 170-column viewport, on the phase 6.1 lazy-allocation build:
//
//   ascii, 90 columns written    29.3 MB -> 14.6 MB   (2.0x)
//   utf8, 60 columns written     29.3 MB ->  9.8 MB   (3.0x)
//   long lines, 170 columns      29.3 MB -> 29.3 MB   (unchanged)
//
// The saving is exactly the gap between what a line is written to and what
// the viewport is wide, so it is worth the most on the output people actually
// keep - shell transcripts, logs - and nothing on a full-width TUI.

// ignore_for_file: deprecated_member_use, invalid_use_of_visible_for_testing_member

import 'package:xterm3/src/terminal.dart';

const _columns = 170;
const _rows = 50;
const _scrollback = 10000;
const _linesWritten = 12000;

void main() {
  final workloads = <String, String Function(int)>{
    'ascii, 90 columns': (i) =>
        '-rw-r--r--  1 user  staff  ${i * 7919 % 1000000} '
        'Aug  2 12:${(i % 60).toString().padLeft(2, '0')} '
        'file_${i}_with_a_reasonably_long_name.dart\r\n',
    'utf8, 60 columns': (i) => 'satır $i — ölçüm değeri ${i * 7919 % 100000} '
        'açıklama_metni_$i şüpheli\r\n',
    'full width, 170 columns': (i) => '${'x' * _columns}\r\n',
  };

  for (final entry in workloads.entries) {
    final terminal = Terminal(maxLines: _scrollback)..resize(_columns, _rows);
    for (var i = 0; i < _linesWritten; i++) {
      terminal.write(entry.value(i));
    }

    var cells = 0;
    final lines = terminal.buffer.lines.length;
    for (var i = 0; i < lines; i++) {
      cells += terminal.buffer.lines[i].data.length ~/ 4;
    }

    print('${entry.key.padRight(24)} $lines lines, '
        '${(cells * 16 / 1024 / 1024).toStringAsFixed(1)} MB retained, '
        '${(cells / lines).toStringAsFixed(0)} cells per line');
  }
}
