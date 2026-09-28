import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The input sources [MacTextInput] can play.
enum MacInputSource {
  /// macOS "ABC": every text key is inserted as it is typed.
  abc,

  /// macOS "2-Set Korean" (두벌식): letter keys are jamo, composed into
  /// syllables by [HangulComposer].
  korean2Set,
}

/// What the Korean input method does with Escape while it is composing.
enum EscapeWhileComposing {
  /// Commits the syllable, then passes the key on as `cancelOperation:`.
  commits,

  /// Drops the syllable, then passes the key on as `cancelOperation:`.
  cancels,
}

/// Plays the macOS side of Flutter's text input in widget tests: the
/// embedder's editing model (`FlutterTextInputPlugin`) and the input method
/// behind it.
///
/// [TestTextInput] pushes editing values into the framework directly, which
/// skips the two things an input method bug lives in. Key events reach the
/// framework first, and the input method only when the framework leaves them
/// unhandled. And a `TextInput.setEditingState` that closes a composition the
/// embedder still has open makes it call `discardMarkedText`, which ends that
/// composition.
///
/// [press] follows the embedder's order: the key goes to the framework,
/// whatever the framework sent while handling it reaches the embedder, and
/// only an unhandled key goes on to the input method. Every editing value
/// the input method produces for one key is delivered before the
/// framework's replies to them are applied, because the embedder sent them
/// all before it could read a reply.
class MacTextInput {
  MacTextInput(this.tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (call) async {
        calls.add(call);
        _toEmbedder.add(call);
        return null;
      },
    );
  }

  final WidgetTester tester;

  /// The input source keys are typed with.
  MacInputSource source = MacInputSource.korean2Set;

  /// Whether the Korean input method commits a syllable with `insertText:`
  /// before passing Enter on as `insertNewline:`. When false it passes Enter
  /// on with the syllable still marked, and the embedder commits it.
  bool enterCommitsWithInsertText = true;

  /// What the Korean input method does with Escape while composing.
  EscapeWhileComposing escape = EscapeWhileComposing.commits;

  /// Every call the framework made on the text input channel, in order.
  final calls = <MethodCall>[];

  /// How many compositions the input method was made to discard because a
  /// `TextInput.setEditingState` closed them.
  int discardedCompositions = 0;

  /// The embedder's editing text.
  String get text => _text;

  final _composer = HangulComposer();
  final _toEmbedder = <MethodCall>[];
  final _toFramework = <MethodCall>[];
  final _pendingSelectors = <String>[];

  int? _client;
  String _inputAction = 'TextInputAction.newline';
  bool _multiline = false;
  String _text = '';
  int _caret = 0;
  bool _composing = false;
  TextRange _composingRange = const TextRange.collapsed(0);

  /// Applies what the framework has sent so far and delivers what the
  /// embedder produced in reply.
  Future<void> settle() async {
    _applyFrameworkCalls();
    await _deliver();
  }

  /// Presses and releases [key], typed with [source].
  ///
  /// Returns whether the framework handled the key down.
  Future<bool> press(MacKey key) async {
    final handled = await _keyDown(key, repeat: false);
    await _keyUp(key);
    return handled;
  }

  /// Presses [key], lets it repeat [repeats] times, and releases it.
  ///
  /// Returns whether the framework handled each repeat.
  Future<List<bool>> hold(MacKey key, {required int repeats}) async {
    await _keyDown(key, repeat: false);
    final handled = [
      for (var i = 0; i < repeats; i++) await _keyDown(key, repeat: true),
    ];
    await _keyUp(key);
    return handled;
  }

  Future<bool> _keyDown(MacKey key, {required bool repeat}) async {
    final character = key.characterFor(source);
    final send = repeat ? tester.sendKeyRepeatEvent : tester.sendKeyDownEvent;
    final handled = await send(
      key.logical,
      physicalKey: key.physical,
      character: character,
    );
    await settle();
    if (!handled) {
      _inputMethodKeyDown(key, character);
      await _deliver();
    }
    return handled;
  }

  Future<void> _keyUp(MacKey key) async {
    await tester.sendKeyUpEvent(key.logical, physicalKey: key.physical);
    await settle();
    await tester.pump();
  }

  /// Presses each key of [keys] in turn.
  Future<void> type(Iterable<MacKey> keys) async {
    for (final key in keys) {
      await press(key);
    }
  }

  /// Plays the platform rewriting committed text, as the macOS accent menu
  /// does when it replaces the `e` it typed with `é`:
  /// `insertText:replacementRange:` with a range over committed text.
  Future<void> replaceCommitted(TextRange range, String replacement) async {
    _text = _text.replaceRange(range.start, range.end, replacement);
    _caret = range.start + replacement.length;
    _sendEditingState();
    await _deliver();
  }

  Future<void> _deliver() async {
    while (_toFramework.isNotEmpty || _pendingSelectors.isNotEmpty) {
      if (_pendingSelectors.isNotEmpty) {
        // The embedder groups selectors per run loop turn and sends them
        // after the editing values of the same turn.
        _toFramework.add(
          MethodCall('TextInputClient.performSelectors', <Object?>[
            _client,
            List<String>.of(_pendingSelectors),
          ]),
        );
        _pendingSelectors.clear();
      }
      final burst = List<MethodCall>.of(_toFramework);
      _toFramework.clear();
      for (final call in burst) {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.textInput.name,
          SystemChannels.textInput.codec.encodeMethodCall(call),
          (_) {},
        );
      }
      _applyFrameworkCalls();
    }
  }

  void _applyFrameworkCalls() {
    while (_toEmbedder.isNotEmpty) {
      final call = _toEmbedder.removeAt(0);
      switch (call.method) {
        case 'TextInput.setClient':
          final arguments = call.arguments as List<Object?>;
          final configuration = arguments[1]! as Map<Object?, Object?>;
          final inputType =
              configuration['inputType'] as Map<Object?, Object?>?;
          _client = arguments[0]! as int;
          _inputAction = configuration['inputAction'] as String? ??
              'TextInputAction.newline';
          _multiline = inputType?['name'] == 'TextInputType.multiline';
          _text = '';
          _caret = 0;
          _endComposing();
          _composer.reset();
        case 'TextInput.clearClient':
          _endComposing();
          _composer.reset();
          _client = null;
        case 'TextInput.setEditingState':
          _setEditingState(
            (call.arguments as Map<Object?, Object?>).cast<String, Object?>(),
          );
      }
    }
  }

  // FlutterTextInputPlugin -setEditingState:
  void _setEditingState(Map<String, Object?> state) {
    final wasComposing = _composing;
    _text = state['text']! as String;
    final extent = state['selectionExtent']! as int;
    _caret = extent < 0 ? 0 : extent;
    final base = state['composingBase']! as int;
    final end = state['composingExtent']! as int;
    _composingRange = base == -1 && end == -1
        ? const TextRange.collapsed(0)
        : TextRange(start: base, end: end);
    _composing = !_composingRange.isCollapsed;
    if (_composingRange.isCollapsed && wasComposing) {
      // [NSTextInputContext discardMarkedText]. The input method commits
      // the syllable it was holding into what is now there.
      if (_composer.isComposing) {
        discardedCompositions++;
        _insertText(_composer.take());
      }
    }
  }

  void _inputMethodKeyDown(MacKey key, String? character) {
    final composing = _composer.isComposing;
    switch (key.role) {
      case MacKeyRole.text:
        final jamo = source == MacInputSource.korean2Set
            ? HangulComposer.jamoOf(character)
            : null;
        if (jamo != null) {
          final result = _composer.add(jamo);
          if (result.commit case final commit?) {
            _insertText(commit);
          }
          _setMarkedText(result.marked);
          return;
        }
        if (composing) {
          _insertText(_composer.take());
        }
        if (character != null && character.isNotEmpty) {
          _insertText(character);
        }
      case MacKeyRole.backspace:
        if (!composing) {
          _doCommand('deleteBackward:');
          return;
        }
        final marked = _composer.backspace();
        if (marked.isEmpty) {
          _insertText('');
        } else {
          _setMarkedText(marked);
        }
      case MacKeyRole.enter:
        if (composing) {
          if (enterCommitsWithInsertText) {
            _insertText(_composer.take());
          } else {
            _composer.reset();
          }
        }
        _doCommand('insertNewline:');
      case MacKeyRole.escape:
        if (composing) {
          switch (escape) {
            case EscapeWhileComposing.commits:
              _insertText(_composer.take());
            case EscapeWhileComposing.cancels:
              _composer.reset();
              _insertText('');
          }
        }
        _doCommand('cancelOperation:');
      case MacKeyRole.command:
        if (composing) {
          _insertText(_composer.take());
        }
        _doCommand(key.selector!);
    }
  }

  // FlutterTextInputPlugin -insertText:replacementRange: (no range).
  void _insertText(String string) {
    if (_composing) {
      _text = _text.replaceRange(
        _composingRange.start,
        _composingRange.end,
        string,
      );
      _caret = _composingRange.start + string.length;
      _endComposing();
    } else {
      _text = _text.replaceRange(_caret, _caret, string);
      _caret += string.length;
    }
    _sendEditingState();
  }

  // FlutterTextInputPlugin -setMarkedText:selectedRange:replacementRange:
  void _setMarkedText(String string) {
    if (!_composing) {
      _composing = true;
      _composingRange = TextRange.collapsed(_caret);
    }
    _text = _text.replaceRange(
      _composingRange.start,
      _composingRange.end,
      string,
    );
    _composingRange = TextRange(
      start: _composingRange.start,
      end: _composingRange.start + string.length,
    );
    _caret = _composingRange.end;
    _sendEditingState();
  }

  // FlutterTextInputPlugin -doCommandBySelector:
  void _doCommand(String selector) {
    if (selector != 'insertNewline:') {
      _pendingSelectors.add(selector);
      return;
    }
    if (_composing) {
      _composingRange = TextRange.collapsed(_composingRange.end);
      _caret = _composingRange.end;
      _endComposing();
    }
    if (_multiline && _inputAction == 'TextInputAction.newline') {
      _insertText('\n');
    }
    _toFramework.add(
      MethodCall('TextInputClient.performAction', <Object?>[
        _client,
        _inputAction,
      ]),
    );
  }

  void _endComposing() {
    _composing = false;
    _composingRange = const TextRange.collapsed(0);
  }

  void _sendEditingState() {
    if (_client == null) {
      return;
    }
    _toFramework.add(
      MethodCall('TextInputClient.updateEditingState', <Object?>[
        _client,
        <String, Object?>{
          'text': _text,
          'selectionBase': _caret,
          'selectionExtent': _caret,
          'selectionAffinity': 'TextAffinity.downstream',
          'selectionIsDirectional': false,
          'composingBase': _composing ? _composingRange.start : -1,
          'composingExtent': _composing ? _composingRange.end : -1,
        },
      ]),
    );
  }
}

/// How the input method treats a key once the framework leaves it unhandled.
enum MacKeyRole { text, backspace, enter, escape, command }

/// A key on a Mac keyboard.
class MacKey {
  const MacKey._(
    this.logical,
    this.physical, {
    required this.role,
    this.latin,
    this.selector,
  });

  /// The letter key typed as [letter] on a US layout.
  factory MacKey.letter(String letter) {
    final (logical, physical) = _letterKeys[letter]!;
    return MacKey._(logical, physical, role: MacKeyRole.text, latin: letter);
  }

  static const space = MacKey._(
    LogicalKeyboardKey.space,
    PhysicalKeyboardKey.space,
    role: MacKeyRole.text,
    latin: ' ',
  );
  static const enter = MacKey._(
    LogicalKeyboardKey.enter,
    PhysicalKeyboardKey.enter,
    role: MacKeyRole.enter,
  );
  static const backspace = MacKey._(
    LogicalKeyboardKey.backspace,
    PhysicalKeyboardKey.backspace,
    role: MacKeyRole.backspace,
  );
  static const escape = MacKey._(
    LogicalKeyboardKey.escape,
    PhysicalKeyboardKey.escape,
    role: MacKeyRole.escape,
  );
  static const arrowLeft = MacKey._(
    LogicalKeyboardKey.arrowLeft,
    PhysicalKeyboardKey.arrowLeft,
    role: MacKeyRole.command,
    selector: 'moveLeft:',
  );
  static const arrowRight = MacKey._(
    LogicalKeyboardKey.arrowRight,
    PhysicalKeyboardKey.arrowRight,
    role: MacKeyRole.command,
    selector: 'moveRight:',
  );
  static const tab = MacKey._(
    LogicalKeyboardKey.tab,
    PhysicalKeyboardKey.tab,
    role: MacKeyRole.command,
    selector: 'insertTab:',
  );

  /// The keys that type [text], lower-case letters and spaces, on a US
  /// layout.
  static List<MacKey> typed(String text) => [
        for (final char in text.split(''))
          char == ' ' ? space : MacKey.letter(char),
      ];

  final LogicalKeyboardKey logical;
  final PhysicalKeyboardKey physical;
  final MacKeyRole role;
  final String? latin;
  final String? selector;

  /// The character macOS attaches to the key event with [source] selected:
  /// the 2-Set layout maps letters straight to compatibility jamo.
  String? characterFor(MacInputSource source) {
    final latin = this.latin;
    if (latin == null) {
      return null;
    }
    if (source == MacInputSource.korean2Set) {
      return HangulComposer.keyToJamo[latin] ?? latin;
    }
    return latin;
  }

  static final _letterKeys =
      <String, (LogicalKeyboardKey, PhysicalKeyboardKey)>{
    'a': (LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA),
    'b': (LogicalKeyboardKey.keyB, PhysicalKeyboardKey.keyB),
    'c': (LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC),
    'd': (LogicalKeyboardKey.keyD, PhysicalKeyboardKey.keyD),
    'e': (LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
    'f': (LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF),
    'g': (LogicalKeyboardKey.keyG, PhysicalKeyboardKey.keyG),
    'h': (LogicalKeyboardKey.keyH, PhysicalKeyboardKey.keyH),
    'i': (LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI),
    'j': (LogicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyJ),
    'k': (LogicalKeyboardKey.keyK, PhysicalKeyboardKey.keyK),
    'l': (LogicalKeyboardKey.keyL, PhysicalKeyboardKey.keyL),
    'm': (LogicalKeyboardKey.keyM, PhysicalKeyboardKey.keyM),
    'n': (LogicalKeyboardKey.keyN, PhysicalKeyboardKey.keyN),
    'o': (LogicalKeyboardKey.keyO, PhysicalKeyboardKey.keyO),
    'p': (LogicalKeyboardKey.keyP, PhysicalKeyboardKey.keyP),
    'q': (LogicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyQ),
    'r': (LogicalKeyboardKey.keyR, PhysicalKeyboardKey.keyR),
    's': (LogicalKeyboardKey.keyS, PhysicalKeyboardKey.keyS),
    't': (LogicalKeyboardKey.keyT, PhysicalKeyboardKey.keyT),
    'u': (LogicalKeyboardKey.keyU, PhysicalKeyboardKey.keyU),
    'v': (LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV),
    'w': (LogicalKeyboardKey.keyW, PhysicalKeyboardKey.keyW),
    'x': (LogicalKeyboardKey.keyX, PhysicalKeyboardKey.keyX),
    'y': (LogicalKeyboardKey.keyY, PhysicalKeyboardKey.keyY),
    'z': (LogicalKeyboardKey.keyZ, PhysicalKeyboardKey.keyZ),
  };
}

/// A 2-Set (두벌식) Hangul composer: jamo in, syllables out.
///
/// It follows the automaton 2-Set input methods share. Double initials come
/// from Shift, not from repeating a consonant. A final consonant followed by
/// a vowel moves to the next syllable (`간` + `ㅏ` → `가나`), and compound
/// finals split to do so (`닭` + `ㅏ` → `달가`). Backspace removes one jamo.
class HangulComposer {
  /// 2-Set letter keys, unshifted, and the compatibility jamo each types.
  static const keyToJamo = <String, String>{
    'r': 'ㄱ', 's': 'ㄴ', 'e': 'ㄷ', 'f': 'ㄹ', 'a': 'ㅁ', 'q': 'ㅂ', //
    't': 'ㅅ', 'd': 'ㅇ', 'w': 'ㅈ', 'c': 'ㅊ', 'z': 'ㅋ', 'x': 'ㅌ', //
    'v': 'ㅍ', 'g': 'ㅎ', 'k': 'ㅏ', 'o': 'ㅐ', 'i': 'ㅑ', 'j': 'ㅓ', //
    'p': 'ㅔ', 'u': 'ㅕ', 'h': 'ㅗ', 'y': 'ㅛ', 'n': 'ㅜ', 'b': 'ㅠ', //
    'm': 'ㅡ', 'l': 'ㅣ',
  };

  static const _initials = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
  static const _medials = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
  // Index 0 is "no final".
  static const _finals = ' ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ';

  static const _compoundMedials = <String, String>{
    'ㅗㅏ': 'ㅘ', 'ㅗㅐ': 'ㅙ', 'ㅗㅣ': 'ㅚ', 'ㅜㅓ': 'ㅝ', //
    'ㅜㅔ': 'ㅞ', 'ㅜㅣ': 'ㅟ', 'ㅡㅣ': 'ㅢ',
  };
  static const _compoundFinals = <String, String>{
    'ㄱㅅ': 'ㄳ', 'ㄴㅈ': 'ㄵ', 'ㄴㅎ': 'ㄶ', 'ㄹㄱ': 'ㄺ', 'ㄹㅁ': 'ㄻ', //
    'ㄹㅂ': 'ㄼ', 'ㄹㅅ': 'ㄽ', 'ㄹㅌ': 'ㄾ', 'ㄹㅍ': 'ㄿ', 'ㄹㅎ': 'ㅀ', //
    'ㅂㅅ': 'ㅄ',
  };

  /// The jamo [character] is, if it is one this composer takes.
  static String? jamoOf(String? character) {
    if (character == null || character.length != 1) {
      return null;
    }
    final isJamo =
        _initials.contains(character) || _medials.contains(character);
    return isJamo ? character : null;
  }

  String? _initial;
  String? _medial;
  String? _final;

  /// Whether a syllable (or a lone jamo) is being composed.
  bool get isComposing => _initial != null || _medial != null;

  /// The text being composed.
  String get marked {
    final initial = _initial;
    final medial = _medial;
    if (initial == null) {
      return medial ?? '';
    }
    if (medial == null) {
      return initial;
    }
    return _syllable(initial, medial, _final);
  }

  /// Adds [jamo]. Returns the text this commits, if any, and what is
  /// composed afterwards.
  ({String? commit, String marked}) add(String jamo) {
    String? commit;
    if (_medials.contains(jamo)) {
      final initial = _initial;
      final medial = _medial;
      final finalJamo = _final;
      if (initial != null && medial != null && finalJamo != null) {
        final split = _splitFinal(finalJamo);
        commit = _syllable(initial, medial, split.$1);
        _initial = split.$2;
        _medial = jamo;
        _final = null;
      } else if (medial == null) {
        _medial = jamo;
      } else if (_compoundMedials['$medial$jamo'] case final compound?) {
        _medial = compound;
      } else {
        commit = marked;
        _initial = null;
        _medial = jamo;
      }
    } else {
      final initial = _initial;
      final medial = _medial;
      final finalJamo = _final;
      if (!isComposing) {
        _initial = jamo;
      } else if (initial == null || medial == null) {
        commit = marked;
        _initial = jamo;
        _medial = null;
      } else if (finalJamo == null && _finals.contains(jamo)) {
        _final = jamo;
      } else if (finalJamo != null &&
          _compoundFinals['$finalJamo$jamo'] != null) {
        _final = _compoundFinals['$finalJamo$jamo'];
      } else {
        commit = marked;
        _initial = jamo;
        _medial = null;
        _final = null;
      }
    }
    return (commit: commit, marked: marked);
  }

  /// Removes the last jamo. Returns what is composed afterwards.
  String backspace() {
    final finalJamo = _final;
    final medial = _medial;
    if (finalJamo != null) {
      // A compound final keeps its first part; a simple one goes.
      _final = _splitFinal(finalJamo).$1;
    } else if (medial != null) {
      final first = _compoundMedials.entries
          .where((entry) => entry.value == medial)
          .map((entry) => entry.key.substring(0, 1))
          .firstOrNull;
      _medial = first;
    } else {
      _initial = null;
    }
    return marked;
  }

  /// Returns what is composed and forgets it.
  String take() {
    final text = marked;
    reset();
    return text;
  }

  void reset() {
    _initial = null;
    _medial = null;
    _final = null;
  }

  /// Splits a final into the part that stays and the part that moves on:
  /// `ㄺ` into `ㄹ` and `ㄱ`, `ㄴ` into nothing and `ㄴ`.
  static (String?, String?) _splitFinal(String finalJamo) {
    for (final entry in _compoundFinals.entries) {
      if (entry.value == finalJamo) {
        return (entry.key.substring(0, 1), entry.key.substring(1));
      }
    }
    return (null, finalJamo);
  }

  static String _syllable(String initial, String medial, String? finalJamo) {
    final code = 0xAC00 +
        (_initials.indexOf(initial) * 21 + _medials.indexOf(medial)) * 28 +
        (finalJamo == null ? 0 : _finals.indexOf(finalJamo));
    return String.fromCharCode(code);
  }
}
