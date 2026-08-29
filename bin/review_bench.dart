// Costs of the paths a code review flagged, measured rather than argued.
//
//   dart compile exe bin/review_bench.dart -o /tmp/review_bench && /tmp/review_bench
//
// JIT numbers (`dart run`) are not comparable to what ships; compile it.
//
// Every row is an absolute cost on the current tree. A finding that is real
// but costs a microsecond a minute does not need fixing, and one that costs a
// millisecond per mouse move does - inspection alone cannot tell them apart,
// which is the point of this file.

import 'package:xterm3/src/core/escape/parser.dart';
import 'package:xterm3/src/core/reflow.dart';
import 'package:xterm3/src/terminal.dart';
import 'package:xterm3/src/terminal_search.dart';
import 'package:xterm3/src/terminal_url_detection.dart';
import 'package:xterm3/src/core/buffer/cell_offset.dart';

import 'noop_escape_handler.dart';

const _columns = 170;
const _rows = 50;

int _sink = 0;

void main() {
  _hoverUrlDetection();
  _wholeWordSearch();
  _reflowAnchors();
  _semanticPromptQueue();
  _oscPayloadJoin();
  _runesVersusCodeUnits();

  print('');
  print('sink=$_sink');
}

// ---------------------------------------------------------------------------
// 2.1 - `urlAt` runs on every hover, whether or not the modifier is down.

void _hoverUrlDetection() {
  _heading('2.1  urlAt on every pointer hover');

  for (final (label, populate) in <(String, void Function(Terminal))>[
    ('plain output, no URL anywhere', _fillPlain),
    ('one URL on the hovered line', _fillWithUrl),
    ('a URL on every line', _fillAllUrls),
  ]) {
    final terminal = Terminal(maxLines: 10000)..resize(_columns, _rows);
    populate(terminal);

    // A hover lands somewhere in the viewport; y is a viewport row.
    final position = CellOffset(40, _rows ~/ 2);
    final perCall = _bench(200000, () {
      final match = terminal.urlAt(position);
      if (match != null) _sink ^= match.text.length;
    });

    _row(label, perCall, '${_perSecond(perCall, 120)} at 120 Hz hover');
  }
}

// ---------------------------------------------------------------------------
// 2.5 - `_isWordCodePoint` builds a one-character String and runs a Unicode
// RegExp for each side of each match.

void _wholeWordSearch() {
  _heading('2.5  wholeWord search word-boundary test');

  final terminal = Terminal(maxLines: 10000)..resize(_columns, _rows);
  _fillPlain(terminal);

  for (final query in ['file', 'staff']) {
    final plain = _bench(200, () {
      _sink ^= terminal.search(query, maxResults: 5000).length;
    });
    final wholeWord = _bench(200, () {
      _sink ^= terminal.search(query, wholeWord: true, maxResults: 5000).length;
    });
    final matches = terminal.search(query, maxResults: 5000).length;

    _row('search("$query") plain', plain, '$matches matches');
    _row('search("$query") wholeWord', wholeWord,
        '+${((wholeWord / plain - 1) * 100).toStringAsFixed(0)}%');
  }
}

// ---------------------------------------------------------------------------
// 2.4 - `BufferLine.anchors` allocates an `UnmodifiableListView` per call, and
// reflow calls it inside its copy loop as well as twice at the end.

void _reflowAnchors() {
  _heading('2.4  reflow with and without anchors on the lines');

  for (final anchorsPerLine in [0, 1]) {
    for (final lineCount in [1000, 10000]) {
      final terminal = Terminal(maxLines: 10000)..resize(_columns, _rows);
      _fillWrapped(terminal, lineCount);

      final lines = terminal.buffer.lines;
      final anchors = <Object>[];
      if (anchorsPerLine > 0) {
        for (var i = 0; i < lines.length; i++) {
          anchors.add(lines[i].createAnchor(0));
        }
      }

      final perReflow = _bench(20, () {
        _sink ^= reflow(lines, _columns, _columns - 10).length;
      });

      _row('reflow $lineCount lines, $anchorsPerLine anchor/line', perReflow,
          '${(perReflow / lineCount).toStringAsFixed(0)} ns per line');
      _sink ^= anchors.length;
    }
  }
}

// ---------------------------------------------------------------------------
// 3.5 - the prune only drops invalid anchors from the front, and every query
// then walks the whole queue calling a validator that scans a line.

void _semanticPromptQueue() {
  _heading('3.5  semantic prompt queries over the anchor queue');

  for (final prompts in [10, 100, 1000]) {
    final terminal = Terminal(maxLines: 10000)..resize(_columns, _rows);
    for (var i = 0; i < prompts; i++) {
      // OSC 133;A marks a prompt start, then a line of output scrolls it up.
      terminal.write('\x1b]133;A\x07user@host:~\$ command $i\r\n');
      terminal.write('output line for command $i\r\n');
    }

    final perCall = _bench(2000, () {
      if (terminal.isSemanticPromptLine(terminal.buffer.lines.length - 2)) {
        _sink++;
      }
    });

    _row('isSemanticPromptLine, $prompts prompts queued', perCall,
        '${(perCall / prompts).toStringAsFixed(0)} ns per queued anchor');
  }
}

// ---------------------------------------------------------------------------
// 4.2 - OSC payloads are split on `;` and immediately rejoined.

void _oscPayloadJoin() {
  _heading('4.2  OSC payload split then rejoin');

  final payloads = <String, String>{
    'OSC 0 title, short': '\x1b]0;~/src/xterm3\x07',
    'OSC 8 hyperlink': '\x1b]8;;https://example.com/a/fairly/long/path\x07'
        'link text\x1b]8;;\x07',
    'OSC 52 clipboard, 8 KiB': '\x1b]52;c;${'QUJDRA==' * 1024}\x07',
  };

  for (final entry in payloads.entries) {
    final parser = EscapeParser(NoopEscapeHandler());
    final perWrite = _bench(20000, () => parser.write(entry.value));
    _row(entry.key, perWrite,
        '${(perWrite / entry.value.length).toStringAsFixed(2)} ns per byte');
  }
}

// ---------------------------------------------------------------------------
// 4.1 - `string.runes` allocates an iterator where `codeUnitAt` would not.
// These sit on key handling, which fires per keystroke, not per byte.

void _runesVersusCodeUnits() {
  _heading('4.1  runes versus codeUnitAt on a one-character key label');

  const label = 'a';
  final runes = _bench(2000000, () {
    if (label.runes.length == 1) _sink ^= label.runes.first;
  });
  final codeUnits = _bench(2000000, () {
    if (label.length == 1) _sink ^= label.codeUnitAt(0);
  });

  _row('runes.length + runes.first', runes, '');
  _row('length + codeUnitAt(0)', codeUnits,
      'saves ${(runes - codeUnits).toStringAsFixed(0)} ns per keystroke');
}

// ---------------------------------------------------------------------------

void _fillPlain(Terminal terminal) {
  for (var line = 0; line < 12000; line++) {
    terminal.write('-rw-r--r--  1 user  staff  ${line * 7919 % 1000000} '
        'Aug  2 12:${(line % 60).toString().padLeft(2, '0')} '
        'file_${line}_with_a_reasonably_long_name.dart\r\n');
  }
}

void _fillWithUrl(Terminal terminal) {
  _fillPlain(terminal);
  terminal.write('\x1b[${_rows ~/ 2 + 1};1H');
  terminal.write('see https://example.com/issues/4821 for the full trace');
}

void _fillAllUrls(Terminal terminal) {
  for (var line = 0; line < 12000; line++) {
    terminal.write('[$line] see https://example.com/issues/$line '
        'and https://docs.example.com/guide/$line for details\r\n');
  }
}

void _fillWrapped(Terminal terminal, int lines) {
  // Lines wider than the viewport, so reflow actually has work to do rather
  // than passing every line straight through its fast path.
  for (var line = 0; line < lines; line++) {
    final text = StringBuffer();
    while (text.length < _columns + 40) {
      text.write('token_${line % 9973}=${line * 7919 % 100000} ');
    }
    terminal.write('$text\r\n');
  }
}

void _heading(String title) {
  print('');
  print(title);
  print('-' * 74);
}

void _row(String label, double nanoseconds, String note) {
  final value = switch (nanoseconds >= 100000) {
    true => '${(nanoseconds / 1000000).toStringAsFixed(2)} ms',
    false => switch (nanoseconds >= 1000) {
        true => '${(nanoseconds / 1000).toStringAsFixed(1)} us',
        false => '${nanoseconds.toStringAsFixed(0)} ns',
      },
  };
  print('  ${label.padRight(42)}${value.padLeft(11)}   $note');
}

String _perSecond(double nanoseconds, int hertz) {
  final share = nanoseconds * hertz / 1000000000 * 100;
  return '${share.toStringAsFixed(2)}% of a core';
}

/// Median of five runs of [iterations] calls, in nanoseconds per call.
double _bench(int iterations, void Function() body) {
  for (var i = 0; i < iterations ~/ 10 + 1; i++) {
    body();
  }

  final samples = <double>[];
  for (var run = 0; run < 5; run++) {
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      body();
    }
    stopwatch.stop();
    samples.add(stopwatch.elapsedMicroseconds * 1000 / iterations);
  }
  samples.sort();
  return samples[2];
}
