import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm3/xterm.dart';

import '../../_support/macos_text_input.dart';

/// Input method behaviour on desktop, where every key reaches the framework
/// as a key event before the platform text input sees it.
///
/// [MacTextInput] plays the macOS embedder and a 2-Set Korean input method,
/// so a test types physical keys and reads what reached the program. The
/// reported failure is SoFluffyOS/lumide#64: `한글테스트` reached the shell as
/// `ㅎㅏㄴㄱㅡㄹㅌㅔㅅㅡㅌㅡ`.
void main() {
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  Future<
      ({
        List<String> output,
        MacTextInput input,
        GlobalKey<TerminalViewState> view
      })> pumpTerminal(WidgetTester tester) async {
    final output = <String>[];
    final input = MacTextInput(tester);
    final view = GlobalKey<TerminalViewState>();
    final terminal = Terminal(
      onOutput: output.add,
      platform: TerminalTargetPlatform.macos,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, key: view, autofocus: true),
        ),
      ),
    );
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    await input.settle();

    return (output: output, input: input, view: view);
  }

  bool isCompatibilityJamo(int rune) => rune >= 0x3131 && rune <= 0x318E;

  testWidgets(
    'leaves a key that types text to the input method',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);

      // 2-Set Korean reports `ㅎ` as the character of the G key.
      final handled = await input.press(MacKey.letter('g'));

      expect(handled, isFalse);
      expect(output, isEmpty);
    },
    variant: macOS,
  );

  group('2-Set Korean reaches the terminal composed', () {
    final cases = <String, (List<MacKey>, String)>{
      'a word': (MacKey.typed('gksrmf '), '한글 '),
      'the lumide#64 string': (
        [...MacKey.typed('gksrmfxptmxm'), MacKey.enter],
        '한글테스트\r',
      ),
      'a final consonant moving on': (MacKey.typed('rksk '), '가나 '),
      'a compound final': (MacKey.typed('ekfr '), '닭 '),
      'a backspace inside a syllable': (
        [...MacKey.typed('gks'), MacKey.backspace, MacKey.space],
        '하 ',
      ),
    };

    for (final MapEntry(key: name, value: (keys, expected)) in cases.entries) {
      testWidgets(
        name,
        (tester) async {
          final (:output, :input, view: _) = await pumpTerminal(tester);

          await input.type(keys);

          expect(output.join(), expected);
          expect(output.join().runes.where(isCompatibilityJamo), isEmpty);
          expect(input.discardedCompositions, 0);
        },
        variant: macOS,
      );
    }
  });

  testWidgets(
    'mixes Latin and Hangul on one line',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);

      input.source = MacInputSource.abc;
      await input.type(MacKey.typed('echo '));
      input.source = MacInputSource.korean2Set;
      await input.type([...MacKey.typed('gks'), MacKey.enter]);

      expect(output.join(), 'echo 한\r');
    },
    variant: macOS,
  );

  testWidgets(
    'does not clear the editing value while the input method composes',
    (tester) async {
      final (output: _, :input, view: _) = await pumpTerminal(tester);
      bool clears(MethodCall call) =>
          call.method == 'TextInput.setEditingState' &&
          (call.arguments as Map)['text'] == '';

      final clearsBefore = input.calls.where(clears).length;
      await input.type(MacKey.typed('gksrmfxptmxm'));

      expect(input.calls.where(clears).length, clearsBefore);
      expect(input.text, '한글테스트');
      expect(input.discardedCompositions, 0);
    },
    variant: macOS,
  );

  testWidgets(
    'clears the editing value once the terminal handles a key',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);

      input.source = MacInputSource.abc;
      await input.type(MacKey.typed('ls'));
      expect(input.text, 'ls');

      expect(await input.press(MacKey.arrowLeft), isTrue);

      expect(input.text, isEmpty);
      expect(output.join(), 'ls\x1b[D');
    },
    variant: macOS,
  );

  testWidgets(
    'does not collapse a letter typed twice',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);

      input.source = MacInputSource.abc;
      await input.type(MacKey.typed('ls all'));

      expect(output.join(), 'ls all');
    },
    variant: macOS,
  );

  testWidgets(
    'keeps key repeat of an ASCII key on the key path',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);
      input.source = MacInputSource.abc;

      // The press goes to the input method; the repeats are written by the
      // terminal, so the macOS accent menu, which needs to see them, never
      // opens.
      final repeats = await input.hold(MacKey.letter('j'), repeats: 2);

      expect(repeats, [true, true]);
      expect(output.join(), 'jjj');
    },
    variant: macOS,
  );

  group('a key the input method passes on while composing', () {
    testWidgets(
      'Enter follows the syllable',
      (tester) async {
        final (:output, :input, view: _) = await pumpTerminal(tester);

        await input.type([...MacKey.typed('gks'), MacKey.enter]);

        expect(output.join(), '한\r');
        expect(input.text, isEmpty);
      },
      variant: macOS,
    );

    testWidgets(
      'Enter follows a syllable the embedder commits',
      (tester) async {
        final (:output, :input, view: _) = await pumpTerminal(tester);
        input.enterCommitsWithInsertText = false;

        await input.type([...MacKey.typed('gks'), MacKey.enter]);

        expect(output.join(), '한\r');
      },
      variant: macOS,
    );

    testWidgets(
      'an arrow key follows the syllable',
      (tester) async {
        final (:output, :input, view: _) = await pumpTerminal(tester);

        await input.type([...MacKey.typed('gk'), MacKey.arrowLeft]);

        expect(output.join(), '하\x1b[D');
      },
      variant: macOS,
    );

    testWidgets(
      'Tab follows the syllable',
      (tester) async {
        final (:output, :input, view: _) = await pumpTerminal(tester);

        await input.type([...MacKey.typed('gk'), MacKey.tab]);

        expect(output.join(), '하\t');
      },
      variant: macOS,
    );

    testWidgets(
      'Escape follows the syllable an input method commits',
      (tester) async {
        final (:output, :input, view: _) = await pumpTerminal(tester);

        await input.type([...MacKey.typed('gk'), MacKey.escape]);

        expect(output.join(), '하\x1b');
      },
      variant: macOS,
    );

    testWidgets(
      'Escape still arrives when the input method drops the syllable',
      (tester) async {
        final (:output, :input, view: _) = await pumpTerminal(tester);
        input.escape = EscapeWhileComposing.cancels;

        await input.type([...MacKey.typed('gk'), MacKey.escape]);

        expect(output.join(), '\x1b');
      },
      variant: macOS,
    );
  });

  testWidgets(
    'replays committed text the platform rewrites',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);
      input.source = MacInputSource.abc;

      await input.type(MacKey.typed('e'));
      // The accent menu replaces the `e` it typed.
      await input.replaceCommitted(const TextRange(start: 0, end: 1), 'é');

      expect(output, ['e', '\x7f', 'é']);
    },
    variant: macOS,
  );

  testWidgets(
    'commitComposing sends only the composition',
    (tester) async {
      final (:output, :input, :view) = await pumpTerminal(tester);

      input.source = MacInputSource.abc;
      await input.type(MacKey.typed('echo '));
      input.source = MacInputSource.korean2Set;
      await input.type(MacKey.typed('gk'));

      expect(view.currentState!.commitComposing(), isTrue);

      expect(output.join(), 'echo 하');
    },
    variant: macOS,
  );

  testWidgets(
    'drops a composition when focus leaves',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);

      await input.type(MacKey.typed('gk'));
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      await input.settle();

      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      await input.settle();

      // Nothing is composing any more, so the terminal takes Enter itself.
      expect(await input.press(MacKey.enter), isTrue);
      expect(output.join(), '\r');
    },
    variant: macOS,
  );

  testWidgets(
    'leaves text keys to the input method on Linux and Windows too',
    (tester) async {
      final (:output, :input, view: _) = await pumpTerminal(tester);
      input.source = MacInputSource.abc;

      expect(await input.press(MacKey.letter('g')), isFalse);

      expect(output.join(), 'g');
    },
    variant: TargetPlatformVariant(
      {TargetPlatform.linux, TargetPlatform.windows},
    ),
  );

  testWidgets(
    'still clears the editing value as soon as a composition resolves on '
    'soft-keyboard platforms',
    (tester) async {
      final output = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(Terminal(onOutput: output.add), autofocus: true),
          ),
        ),
      );
      await tester.tap(find.byType(TerminalView));
      await tester.pump();

      tester.testTextInput.enterText('ls');
      await tester.pump();

      expect(output.join(), 'ls');
      expect(tester.testTextInput.editingState?['text'], '');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  group('MacTextInput', () {
    // A client that clears the editing value as soon as a composition
    // resolves, as xterm3 6.3.4 did. If the fake did not model the race, it
    // would pass here too and the tests above would prove nothing.
    testWidgets(
      'reproduces the race an eager clear runs into',
      (tester) async {
        final input = MacTextInput(tester);
        final client = _EagerClient();
        client.connection = TextInput.attach(
          client,
          const TextInputConfiguration(),
        )..setEditingState(TextEditingValue.empty);
        await input.settle();

        await input.type(MacKey.typed('gksrmf '));

        expect(input.discardedCompositions, greaterThan(0));
        expect(client.sent.join(), isNot('한글 '));
        expect(client.sent.join().runes.any(isCompatibilityJamo), isTrue);

        client.connection!.close();
      },
      variant: macOS,
    );
  });
}

class _EagerClient with TextInputClient {
  TextInputConnection? connection;
  final sent = <String>[];

  @override
  void updateEditingValue(TextEditingValue value) {
    if (value.composing.isCollapsed && value.text.isNotEmpty) {
      sent.add(value.text);
      connection!.setEditingState(TextEditingValue.empty);
    }
  }

  @override
  TextEditingValue? get currentTextEditingValue => null;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {}
}
