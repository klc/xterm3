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

    consumer.consumeAsciiCodeUnits(1024);
    consumer.unrefConsumedBlocks();

    expect(consumer.currentBlock, 'pending');
    expect(consumer.currentCodeUnitOffset, 0);
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

  test('single-cell runs span Latin-1, Greek and Cyrillic', () {
    final consumer = ByteConsumer()..add('göz строка\u{0301}');

    // Stops at the combining acute, which is not a single-cell character.
    expect(consumer.printableTextRunLength, 'göz строка'.length);
    // The ASCII-only scan stops at the first accented letter instead.
    expect(consumer.printableAsciiRunLength, 1);
  });

  test('single-cell runs span dashes, box drawing and braille', () {
    final consumer = ByteConsumer()..add('a \u{2014} ┌──┐ ▁▂▃ ⣿⣀\u{4E00}');

    expect(consumer.printableTextRunLength, 'a \u{2014} ┌──┐ ▁▂▃ ⣿⣀'.length);
  });

  test('single-cell runs stop at characters that need the slow path', () {
    // Soft hyphen and the zero width joiner are zero width; CJK is outside
    // the ranges; an emoji is a surrogate pair.
    for (final text in [
      'a\u{00AD}b',
      'a\u{200D}b',
      'a\u{4E00}b',
      'a\u{1F600}b'
    ]) {
      final consumer = ByteConsumer()..add(text);
      expect(consumer.printableTextRunLength, 1, reason: text);
    }
  });

  test('a run carried on from a wide code unit takes single-cell text too', () {
    final consumer = ByteConsumer()..add('ab中文、ＡＢcd\u{0301}');

    // The single-cell scan stops at the first wide character.
    expect(consumer.printableTextRunLength, 2);
    consumer.consumeAsciiCodeUnits(2);
    expect(consumer.consume(), '中'.codeUnitAt(0));
    expect(consumer.headBlock, 'ab中文、ＡＢcd\u{0301}');
    expect(consumer.headOffset, 3);
    // From there to the combining acute.
    expect(consumer.textRunEndInHead(), 'ab中文、ＡＢcd'.length);
  });

  test('a run carried on from a wide code unit stops at the slow path', () {
    // A voicing mark (Extend), an emoji (surrogate pair), a Hangul leading
    // jamo and ESC end it; the end of the head block ends it too.
    for (final (text, end) in [
      ('中か\u{3099}a', 2),
      ('中\u{1F600}', 1),
      ('中a\u{1100}가', 2),
      ('中a中\x1b[m', 3),
      ('中a中', 3),
    ]) {
      final consumer = ByteConsumer()
        ..add(text)
        ..add('中');
      expect(consumer.consume(), '中'.codeUnitAt(0), reason: text);
      expect(consumer.textRunEndInHead(), end, reason: text);
    }
  });

  test('consumes printable ASCII runs without crossing controls or blocks', () {
    final consumer = ByteConsumer()
      ..add('abc\x1b')
      ..add('def');

    expect(consumer.printableAsciiRunLength, 3);
    expect(consumer.currentBlock, 'abc\x1b');
    expect(consumer.currentCodeUnitOffset, 0);

    consumer.consumeAsciiCodeUnits(3);
    expect(consumer.totalConsumed, 3);
    expect(consumer.consume(), 0x1b);
    expect(consumer.printableAsciiRunLength, 3);

    consumer.consumeAsciiCodeUnits(3);
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
      expect(consumer.currentCodeUnitOffset, 1);
      expect(consumer.printableTextRunLength, 1);
      expect(consumer.consume(), 0x62);
      expect(consumer.currentBlock, 'cd');
      expect(consumer.printableTextRunLength, 2);
      expect(_consumeAll(consumer), 'cd'.runes);
    });

    test('when a block is added to an emptied queue', () {
      final consumer = ByteConsumer()..add('ab');
      _consumeAll(consumer);
      consumer.unrefConsumedBlocks();
      consumer.add('xyz');

      expect(consumer.currentBlock, 'xyz');
      expect(consumer.currentCodeUnitOffset, 0);
      expect(consumer.printableTextRunLength, 3);
      consumer.consumeAsciiCodeUnits(2);
      expect(consumer.consume(), 0x7a);
      expect(consumer, isEmpty);
    });

    test('when a rollback crosses a block edge', () {
      final consumer = ByteConsumer()
        ..add('ab')
        ..add('cd');
      consumer.consumeAsciiCodeUnits(2);
      expect(consumer.consume(), 0x63);
      expect(consumer.currentBlock, 'cd');

      consumer.rollback(2);
      expect(consumer.currentBlock, 'ab');
      expect(consumer.currentCodeUnitOffset, 1);
      expect(consumer.printableTextRunLength, 1);
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
      expect(consumer.currentCodeUnitOffset, 1);
      expect(_consumeAll(consumer), '😀😁'.runes);
    });

    test('when peeking at the last code unit of a block', () {
      final consumer = ByteConsumer()
        ..add('xa')
        ..add('b');
      consumer.consume();
      expect(consumer.peek(), 0x61);
      expect(consumer.currentBlock, 'xa');
      expect(consumer.currentCodeUnitOffset, 1);
      expect(consumer.consume(), 0x61);
      expect(consumer.peek(), 0x62);
      expect(consumer.currentBlock, 'b');
      expect(consumer.currentCodeUnitOffset, 0);
      expect(_consumeAll(consumer), 'b'.runes);
    });

    test('when unref cuts the head block and more is added', () {
      final consumer = ByteConsumer()..add('abc');
      consumer.consume();
      consumer.consume();
      consumer.unrefConsumedBlocks();
      expect(consumer.currentBlock, 'c');
      expect(consumer.currentCodeUnitOffset, 0);

      consumer.add('de');
      expect(consumer.printableTextRunLength, 1);
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
