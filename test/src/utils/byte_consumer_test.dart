import 'package:test/test.dart';
import 'package:xterm3/src/utils/byte_consumer.dart';

void main() {
  test('consumes fragmented ASCII without changing offsets', () {
    final consumer = ByteConsumer()
      ..add('abc')
      ..add('def');

    expect(consumer.length, 6);
    expect(_consumeAll(consumer), 'abcdef'.runes);
    expect(consumer.totalConsumed, 6);
  });

  test('decodes supplementary code points lazily', () {
    final consumer = ByteConsumer()..add('a😀b');

    expect(consumer.length, 3);
    expect(consumer.consume(), 0x61);
    expect(consumer.peek(), 0x1f600);
    expect(consumer.consume(), 0x1f600);
    expect(consumer.consume(), 0x62);
  });

  test('matches Runes behavior for malformed surrogates', () {
    final malformed = String.fromCharCodes([0xd800, 0x61, 0xdc00]);
    final consumer = ByteConsumer()..add(malformed);

    expect(_consumeAll(consumer), malformed.runes);
  });

  test('rolls back across string block boundaries', () {
    final consumer = ByteConsumer()
      ..add('a😀')
      ..add('bc');

    expect(consumer.consume(), 0x61);
    expect(consumer.consume(), 0x1f600);
    expect(consumer.consume(), 0x62);
    consumer.rollback(2);

    expect(consumer.length, 3);
    expect(consumer.totalConsumed, 1);
    expect(_consumeAll(consumer), '😀bc'.runes);
  });

  test('rolls back to a recorded rune length', () {
    final consumer = ByteConsumer()..add('a😀bc');
    final initialLength = consumer.length;

    consumer.consume();
    consumer.consume();
    consumer.rollbackTo(initialLength);

    expect(_consumeAll(consumer), 'a😀bc'.runes);
  });

  test('drops consumed blocks before accepting more output', () {
    final consumer = ByteConsumer()..add('first');
    _consumeAll(consumer);

    consumer.unrefConsumedBlocks();
    consumer.add('second');

    expect(_consumeAll(consumer), 'second'.runes);
  });

  test('releases consumed prefixes while preserving pending input', () {
    final consumer = ByteConsumer()..add('${'x' * 1024}pending');

    consumer.consumeHeadTo(1024);
    consumer.unrefConsumedBlocks();

    expect(consumer.currentBlock, 'pending');
    expect(consumer.headOffset, 0);
    expect(_consumeAll(consumer), 'pending'.runes);
  });

  test('handles large ASCII output without changing parser semantics', () {
    final text = 'x' * 1024 * 1024;
    final consumer = ByteConsumer()..add(text);

    expect(consumer.length, text.length);
    var consumed = 0;
    while (consumer.isNotEmpty) {
      if (consumer.consume() != 0x78) {
        fail('ASCII output changed at rune $consumed');
      }
      consumed++;
    }
    expect(consumed, text.length);
    expect(consumer, isEmpty);
  });

  test('reports remaining rune length without eager block metadata', () {
    final consumer = ByteConsumer()
      ..add('a😀')
      ..add('b😁c');

    expect(consumer.length, 5);
    expect(consumer.consume(), 0x61);
    expect(consumer.length, 4);
    expect(consumer.consume(), 0x1f600);
    expect(consumer.length, 3);

    consumer.rollback(2);

    expect(consumer.length, 5);
    expect(_consumeAll(consumer), 'a😀b😁c'.runes);
  });

  test('a run carried on from a wide character takes single-cell text too', () {
    final consumer = ByteConsumer()..add('ab中文、ＡＢcd😀ef\u{0301}');

    consumer.consumeHeadTo(2);
    expect(consumer.consume(), '中'.codeUnitAt(0));
    expect(consumer.headBlock, 'ab中文、ＡＢcd😀ef\u{0301}');
    expect(consumer.headOffset, 3);
    final before = consumer.totalConsumed;
    // From there to the combining acute, the emoji counted as one.
    expect(consumer.consumeTextRunInHead(), 'ab中文、ＡＢcd😀ef'.length);
    expect(consumer.totalConsumed - before, '文、ＡＢcd😀ef'.runes.length);
    expect(consumer.consume(), 0x0301);
  });

  test('a run carried on from a wide character stops at the slow path', () {
    // A voicing mark (Extend), a skin tone, a ZWJ, a regional indicator, a
    // Hangul leading jamo and ESC end it; the end of the head block too.
    for (final (text, end) in [
      ('中か\u{3099}a', 2),
      ('中😀\u{1F3FB}', 3),
      ('中😀\u200d😀', 3),
      ('中\u{1F1FA}\u{1F1F8}', 1),
      ('中a\u{1100}가', 2),
      ('中a中\x1b[m', 3),
      ('中a😀', 4),
    ]) {
      final consumer = ByteConsumer()
        ..add(text)
        ..add('中');
      expect(consumer.consume(), '中'.codeUnitAt(0), reason: text);
      expect(consumer.consumeTextRunInHead(), end, reason: text);
    }
  });

  test('consumes scanned runs without crossing controls or blocks', () {
    final consumer = ByteConsumer()
      ..add('abc\x1b')
      ..add('def');

    expect(consumer.printableAsciiRunLength, 3);
    expect(consumer.currentBlock, 'abc\x1b');
    expect(consumer.headOffset, 0);

    consumer.consumeHeadTo(3);
    expect(consumer.totalConsumed, 3);
    expect(consumer.consume(), 0x1b);
    expect(consumer.printableAsciiRunLength, 3);
    expect(consumer.headBlock, 'def');

    consumer.consumeHeadTo(3);
    expect(consumer.totalConsumed, 7);
    expect(consumer, isEmpty);

    consumer.rollback(3);
    expect(_consumeAll(consumer), 'def'.runes);
  });
  // ByteConsumer keeps the head block's string in a field (see the class
  // comment). These cover each place where the head block changes.
  group('the cached head block follows the queue', () {
    test('when a block is added after a partial consume', () {
      final consumer = ByteConsumer()..add('ab');
      expect(consumer.consume(), 0x61);
      consumer.add('cd');

      expect(consumer.currentBlock, 'ab');
      expect(consumer.headOffset, 1);
      expect(consumer.printableAsciiRunLength, 1);
      expect(consumer.consume(), 0x62);
      expect(consumer.currentBlock, 'cd');
      expect(consumer.printableAsciiRunLength, 2);
      expect(_consumeAll(consumer), 'cd'.runes);
    });

    test('when a block is added to an emptied queue', () {
      final consumer = ByteConsumer()..add('ab');
      _consumeAll(consumer);
      consumer.unrefConsumedBlocks();
      consumer.add('xyz');

      expect(consumer.currentBlock, 'xyz');
      expect(consumer.headOffset, 0);
      expect(consumer.printableAsciiRunLength, 3);
      consumer.consumeHeadTo(2);
      expect(consumer.consume(), 0x7a);
      expect(consumer, isEmpty);
    });

    test('when a rollback crosses a block edge', () {
      final consumer = ByteConsumer()
        ..add('ab')
        ..add('cd');
      consumer.consumeHeadTo(2);
      expect(consumer.consume(), 0x63);
      expect(consumer.currentBlock, 'cd');

      consumer.rollback(2);
      expect(consumer.currentBlock, 'ab');
      expect(consumer.headOffset, 1);
      expect(consumer.printableAsciiRunLength, 1);
      expect(_consumeAll(consumer), 'bcd'.runes);
    });

    test('when a rollback crosses a block edge inside a surrogate pair', () {
      final consumer = ByteConsumer()
        ..add('a😀')
        ..add('😁');
      consumer.consume();
      consumer.consume();
      consumer.consume();
      consumer.rollback(2);
      expect(consumer.currentBlock, 'a😀');
      expect(consumer.headOffset, 1);
      expect(_consumeAll(consumer), '😀😁'.runes);
    });

    test('when peeking at the last code unit of a block', () {
      final consumer = ByteConsumer()
        ..add('xa')
        ..add('b');
      consumer.consume();
      expect(consumer.peek(), 0x61);
      expect(consumer.currentBlock, 'xa');
      expect(consumer.headOffset, 1);
      expect(consumer.consume(), 0x61);
      expect(consumer.peek(), 0x62);
      expect(consumer.currentBlock, 'b');
      expect(consumer.headOffset, 0);
      expect(_consumeAll(consumer), 'b'.runes);
    });

    test('when unref cuts the head block and more is added', () {
      final consumer = ByteConsumer()..add('abc');
      consumer.consume();
      consumer.consume();
      consumer.unrefConsumedBlocks();
      expect(consumer.currentBlock, 'c');
      expect(consumer.headOffset, 0);

      consumer.add('de');
      expect(consumer.printableAsciiRunLength, 1);
      expect(_consumeAll(consumer), 'cde'.runes);
    });

    test('when an unfinished sequence is put back and the next write lands',
        () {
      // What EscapeParser.write does when a chunk ends inside a sequence.
      final consumer = ByteConsumer()..add('x\x1b[1');
      expect(consumer.consume(), 0x78);
      consumer.consume();
      consumer.consume();
      consumer.consume();
      consumer.rollback(3);
      consumer.unrefConsumedBlocks();
      expect(consumer.currentBlock, '\x1b[1');

      consumer.add('m');
      expect(_consumeAll(consumer), '\x1b[1m'.runes);
    });

    test('when it is reset', () {
      final consumer = ByteConsumer()
        ..add('ab')
        ..add('cd');
      consumer.consume();
      consumer.reset();
      expect(consumer, isEmpty);

      consumer.add('z');
      expect(consumer.currentBlock, 'z');
      expect(_consumeAll(consumer), 'z'.runes);
    });

    test('when a consume runs past the end', () {
      final consumer = ByteConsumer();
      expect(consumer.consume, throwsStateError);

      consumer.add('a');
      consumer.consume();
      expect(consumer.consume, throwsStateError);

      consumer.add('b');
      expect(consumer.currentBlock, 'b');
      expect(_consumeAll(consumer), 'b'.runes);
    });
  });
}

List<int> _consumeAll(ByteConsumer consumer) {
  final output = <int>[];
  while (consumer.isNotEmpty) {
    output.add(consumer.consume());
  }
  return output;
}
