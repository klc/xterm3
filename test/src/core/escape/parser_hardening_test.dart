import 'dart:io';

import 'package:test/test.dart';
import 'package:xterm3/core.dart';

void main() {
  group('CSI numeric parameters', () {
    const huge = '18446744073709551615';

    for (final finalBytes in ['L', 'M', 'S', 'T', '@', 'P', "'}", "'~", 'b']) {
      for (final param in [huge, '20000000']) {
        test('parameter $param for $finalBytes does not throw or stall', () {
          final terminal = Terminal();
          final stopwatch = Stopwatch()..start();

          terminal.write('A\x1b[$param${finalBytes}B-after');

          stopwatch.stop();
          expect(stopwatch.elapsedMilliseconds, lessThan(200));
          final text = terminal.buffer.lines.toList().map((l) => l.getText());
          expect(text.join('\n'), contains('B-after'));
        });
      }
    }
  });

  group('ESC with intermediate bytes', () {
    const sequences = [
      '\x1b%G',
      '\x1b%@',
      '\x1b F',
      '\x1b G',
      '\x1b-A',
      '\x1b.A',
      '\x1b/A',
      '\x1b\$(D',
    ];

    for (final sequence in sequences) {
      final name = sequence.substring(1);

      test('ESC $name is discarded', () {
        final terminal = Terminal();
        terminal.write('<$sequence>');
        expect(terminal.buffer.lines[0].getText(), '<>');
      });

      test('ESC $name is discarded when split byte by byte', () {
        final terminal = Terminal();
        for (final char in '<$sequence>'.split('')) {
          terminal.write(char);
        }
        expect(terminal.buffer.lines[0].getText(), '<>');
      });
    }

    test('charset designation and ESC # still work', () {
      final terminal = Terminal();
      terminal.write('\x1b(0q\x1b(B');
      expect(terminal.buffer.lines[0].getText(), '─');

      terminal.write('\x1b#8');
      expect(terminal.buffer.lines[1].getText(), 'E' * terminal.viewWidth);
    });
  });

  group('unfinished ESC sequence written in many chunks', () {
    // An ESC with an intermediate byte, a charset designation and ESC # wait
    // for their final byte through DEL, C0 controls and (the first)
    // intermediates. Each write used to read the whole sequence again, so a
    // BEL in it rang once more with every later write.
    for (final (name, start, filler) in [
      ('ESC + intermediates', '\x1b ${' ' * 4096}', ' '),
      ('ESC ( + DEL', '\x1b(${'\x7f' * 4096}', '\x7f'),
    ]) {
      test('$name: a BEL in each write rings once', () {
        var bells = 0;
        final terminal = Terminal(onBell: () => bells++);

        terminal.write(start);
        for (var i = 0; i < 100; i++) {
          terminal.write('\x07$filler');
        }
        terminal.write('Xafter');

        expect(bells, 100);
        expect(terminal.buffer.lines[0].getText(), 'after');
      });
    }

    // Past the limit (256 bytes) the sequence ends as it does when written
    // whole, wherever the writes cut it.
    const limit = 256;
    final del = '\x7f' * (limit + 50);
    for (final (input, line, expected) in [
      ('\x1b($del' '0q', 0, '─'),
      ('\x1b#$del' '8', 0, 'E' * 80),
      ('\x1b${' ' * (limit + 50)}Fafter', 0, 'after'),
    ]) {
      final chunkings = [
        [input],
        input.split(''),
        for (var cut = limit - 1; cut <= limit + 3; cut++)
          [input.substring(0, cut), input.substring(cut)],
      ];
      for (final chunks in chunkings) {
        test(
            'over-long ${input.substring(1, 2)} ends the same in '
            '${chunks.length} writes of ${chunks.first.length}', () {
          final terminal = Terminal();
          for (final chunk in chunks) {
            terminal.write(chunk);
          }
          expect(terminal.buffer.lines[line].getText(), expected);
        });
      }
    }
  });

  group('SGR colon truecolor', () {
    test('without colour space followed by more parameters', () {
      final terminal = Terminal();

      terminal.write('\x1b[38:2:255:0:0;1mX');

      final line = terminal.buffer.lines[0];
      expect(line.getForeground(0), CellColor.rgb | 0xff0000);
      expect(line.getAttributes(0) & CellAttr.bold, isNot(0));
    });

    test('foreground and background without colour space', () {
      final terminal = Terminal();

      terminal.write('\x1b[38:2:255:0:0;48:2:0:0:255;58:2:1:2:3mX');

      final line = terminal.buffer.lines[0];
      expect(line.getForeground(0), CellColor.rgb | 0xff0000);
      expect(line.getBackground(0), CellColor.rgb | 0x0000ff);
      expect(line.getUnderlineColor(0), CellColor.rgb | 0x010203);
    });

    test('with colour space and semicolon forms stay correct', () {
      final terminal = Terminal();

      terminal.write('\x1b[38:2::255:0:0;1mX\x1b[0;38;2;0;255;0;1mY');

      final line = terminal.buffer.lines[0];
      expect(line.getForeground(0), CellColor.rgb | 0xff0000);
      expect(line.getAttributes(0) & CellAttr.bold, isNot(0));
      expect(line.getForeground(1), CellColor.rgb | 0x00ff00);
      expect(line.getAttributes(1) & CellAttr.bold, isNot(0));
    });
  });

  group('OSC length limit', () {
    for (var length = 8188; length <= 8193; length++) {
      test('terminator after $length payload bytes ends the OSC', () {
        final terminal = Terminal();

        terminal.write('\x1b]2;${'x' * length}\x07HELLO-VISIBLE\r\nnext');

        expect(terminal.buffer.lines[0].getText(), 'HELLO-VISIBLE');
        expect(terminal.buffer.lines[1].getText(), 'next');
      });

      test('ST after $length payload bytes ends the OSC', () {
        final terminal = Terminal();

        terminal.write('\x1b]2;${'x' * length}\x1b\\HELLO-VISIBLE');

        expect(terminal.buffer.lines[0].getText(), 'HELLO-VISIBLE');
      });
    }
  });

  test('XTVERSION reports the pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1)!;
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[>q');

    expect(output.single, contains('xterm3 $version'));
  });
}
