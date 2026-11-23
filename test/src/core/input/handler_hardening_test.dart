import 'package:test/test.dart';
import 'package:xterm3/xterm.dart';

void main() {
  group('modifyOtherKeys mode 2', () {
    late List<String> output;
    late Terminal terminal;

    setUp(() {
      output = <String>[];
      terminal = Terminal(onOutput: output.add)..write('\x1b[>4;2m');
    });

    test('leaves unmodified and shift-only text keys to text input', () {
      expect(terminal.keyInput(TerminalKey.keyA, text: 'a'), isFalse);
      expect(
          terminal.keyInput(TerminalKey.keyA, shift: true, text: 'A'), isFalse);
      expect(terminal.keyInput(TerminalKey.bracketLeft, text: '['), isFalse);
      expect(
        terminal.keyInput(TerminalKey.bracketLeft, shift: true, text: '{'),
        isFalse,
      );
      expect(terminal.keyInput(TerminalKey.keyA), isFalse);

      expect(output, isEmpty);
    });

    test('still encodes Ctrl, Alt, Meta and Shift+Space', () {
      terminal.keyInput(TerminalKey.keyA, ctrl: true, text: 'a');
      terminal.keyInput(TerminalKey.keyA, alt: true, text: 'a');
      terminal.keyInput(TerminalKey.keyA, superKey: true, text: 'a');
      terminal.keyInput(TerminalKey.keyA, shift: true, ctrl: true, text: 'A');
      terminal.keyInput(TerminalKey.space, shift: true, text: ' ');

      expect(output, [
        '\x1b[27;5;97~',
        '\x1b[27;3;97~',
        '\x1b[27;9;97~',
        '\x1b[27;6;65~',
        '\x1b[27;2;32~',
      ]);
    });

    test('keeps Shift+Enter distinct', () {
      terminal.keyInput(TerminalKey.enter, shift: true);

      expect(output, ['\x1b[27;2;13~']);
    });

    test('encodes the key, not the C0 control macOS gives as Ctrl text', () {
      // AppKit applies Control to the characters: Ctrl+P arrives as `\x10`.
      terminal.keyInput(TerminalKey.keyP, ctrl: true, text: '\x10');
      terminal.keyInput(TerminalKey.keyA,
          shift: true, ctrl: true, text: '\x01');

      expect(output, ['\x1b[27;5;112~', '\x1b[27;6;65~']);
    });

    test('keeps the control text of a key with no character', () {
      terminal.keyInput(TerminalKey.tab, ctrl: true, text: '\t');

      expect(output, ['\x1b[27;5;9~']);
    });

    test('leaves legacy Ctrl+P a C0 control when the mode is off', () {
      final legacyOutput = <String>[];
      Terminal(onOutput: legacyOutput.add)
          .keyInput(TerminalKey.keyP, ctrl: true, text: '\x10');

      expect(legacyOutput, ['\x10']);
    });
  });
}
