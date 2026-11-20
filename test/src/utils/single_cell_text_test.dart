import 'package:characters/characters.dart';
import 'package:test/test.dart';
import 'package:xterm3/src/utils/single_cell_text.dart';
import 'package:xterm3/src/utils/unicode_v11.dart';

void main() {
  test('every single-cell printable is width 1 and starts its own grapheme',
      () {
    // The two properties a batched write relies on, checked for every code
    // unit the predicate accepts rather than for the ranges it is written in.
    var accepted = 0;
    for (var codeUnit = 0; codeUnit <= 0xffff; codeUnit++) {
      if (!isSingleCellPrintable(codeUnit)) continue;
      accepted++;
      expect(unicodeV11.wcwidth(codeUnit), 1,
          reason: 'U+${codeUnit.toRadixString(16)}');
      final char = String.fromCharCode(codeUnit);
      for (final previous in ['a', 'é', 'я', '中', '─', '\u{1F600}']) {
        expect((previous + char).characters.length, 2,
            reason: 'U+${codeUnit.toRadixString(16)} after $previous');
      }
    }
    expect(accepted, greaterThan(1500));
  });

  test('box drawing, block elements, braille and dashes are in the set', () {
    for (final codeUnit in [0x2014, 0x2026, 0x2500, 0x256c, 0x2588, 0x28ff]) {
      expect(isSingleCellPrintable(codeUnit), isTrue,
          reason: 'U+${codeUnit.toRadixString(16)}');
    }
  });

  test('zero-width and wide characters stay out of the set', () {
    for (final codeUnit in [0xad, 0x300, 0x200b, 0x200d, 0x2028, 0x4e00]) {
      expect(isSingleCellPrintable(codeUnit), isFalse,
          reason: 'U+${codeUnit.toRadixString(16)}');
    }
  });

  test('every wide run unit is width 2 and joins no run character', () {
    // What Buffer.writeMixedWidth relies on, for every code unit accepted:
    // two cells, and no cluster across it and a run character either way.
    // The bases cover the narrow run set and the wide one.
    const runBases = ['a', 'é', 'я', '─', '中', '가', 'あ', 'ー', '、', 'Ａ'];
    var accepted = 0;
    for (var codeUnit = 0; codeUnit <= 0xffff; codeUnit++) {
      if (!isWideRunUnit(codeUnit)) continue;
      accepted++;
      final reason = 'U+${codeUnit.toRadixString(16)}';
      expect(unicodeV11.wcwidth(codeUnit), 2, reason: reason);
      expect(isSingleCellPrintable(codeUnit), isFalse, reason: reason);
      final char = String.fromCharCode(codeUnit);
      for (final base in [...runBases, char]) {
        expect('$base$char'.characters.length, 2,
            reason: '$reason after $base');
        expect('$char$base'.characters.length, 2,
            reason: '$reason before $base');
      }
    }
    expect(accepted, greaterThan(39000));
  });

  test('wide run units take CJK punctuation, kana, Han, Hangul, fullwidth', () {
    for (final codeUnit in [
      0x3000, 0x3001, 0x300c, 0x3042, 0x30fc, 0x30fb, 0x4e00, 0x9fff, //
      0x3400, 0xac00, 0xd7a3, 0x3131, 0xf900, 0xff01, 0xff21, 0xffe5,
    ]) {
      expect(isWideRunUnit(codeUnit), isTrue,
          reason: 'U+${codeUnit.toRadixString(16)}');
    }
    // Extend marks, a width-1 and a width-0 code point inside those blocks,
    // the Hangul leading jamo, and emoji (surrogates) stay out.
    for (final codeUnit in [
      0x302a,
      0x3099,
      0x303f,
      0x3164,
      0x1100,
      0xd83d,
      0x2e80,
      0x61,
    ]) {
      expect(isWideRunUnit(codeUnit), isFalse,
          reason: 'U+${codeUnit.toRadixString(16)}');
    }
  });

  // Every code point except the surrogates, which cannot stand alone in a
  // String.
  Iterable<int> allCodePoints() sync* {
    for (var codePoint = 0; codePoint <= 0x10ffff; codePoint++) {
      if (codePoint < 0xd800 || codePoint > 0xdfff) yield codePoint;
    }
  }

  String hex(int codePoint) => 'U+${codePoint.toRadixString(16)}';

  test('isGraphemePrepend matches segmentation for every code point', () {
    // GB9b: a Prepend code point joins even a plain letter after it, and
    // nothing else does.
    for (final codePoint in allCodePoints()) {
      final joins = '${String.fromCharCode(codePoint)}a'.characters.length == 1;
      expect(isGraphemePrepend(codePoint), joins, reason: hex(codePoint));
    }
  });

  test('isHangulLeadingJamo matches segmentation for every code point', () {
    // GB6: only a leading jamo (or a Prepend code point, GB9b) is joined by a
    // following leading jamo.
    for (final codePoint in allCodePoints()) {
      final char = String.fromCharCode(codePoint);
      final joins = '$char\u1100'.characters.length == 1 &&
          '${char}a'.characters.length == 2;
      expect(isHangulLeadingJamo(codePoint), joins, reason: hex(codePoint));
    }
  });

  // One base of every Grapheme_Cluster_Break class a cell can hold, except
  // Prepend and L: Other, wide Other, LV, LVT, V, T, a V outside Hangul,
  // regional indicator, SpacingMark, a width-1 Extend, ZWJ, Control,
  // Extended_Pictographic, an Indic consonant and a virama.
  const otherBases = [
    'a', '中', '가', '각', '\u1161', '\u11a8', '\u{16d63}', '\u{1f1e6}', //
    '\u093f', '\uff9e', '\u200d', '\u2028', '\u{1f600}', '\u0915', '\u094d',
  ];

  test('a wide code point joins only after Prepend, Hangul L or ZWJ', () {
    // The claim the wide shortcut in Buffer._joinsPreviousGrapheme rests on,
    // from both sides. Every wide code point other than an emoji modifier
    // starts a new grapheme after a base of every other class and after
    // clusters that end in a mark, VS16, a modifier, a flag, a virama or a
    // jamo...
    for (final codePoint in allCodePoints()) {
      if (unicodeV11.wcwidth(codePoint) != 2) continue;
      if (codePoint >= 0x1f3fb && codePoint <= 0x1f3ff) continue;
      final char = String.fromCharCode(codePoint);
      for (final cluster in [
        ...otherBases,
        'e\u0301',
        '\u2764\ufe0f',
        '\u{1f44d}\u{1f3fd}',
        '\u{1f1e6}\u{1f1e7}',
        '\u0915\u094d',
        '\u1100\u1161',
        '\uac00\u11a8',
        '\u{1f600}\u200d\u{1f600}',
      ]) {
        expect('$cluster$char'.characters.length, cluster.characters.length + 1,
            reason: '${hex(codePoint)} after ${hex(cluster.runes.last)}');
      }
    }
    // ... and every base other than Prepend and L is left by every kind of
    // wide code point: ideograph, kana, syllable, leading jamo, emoji.
    for (final codePoint in allCodePoints()) {
      if (isGraphemePrepend(codePoint) || isHangulLeadingJamo(codePoint)) {
        continue;
      }
      final base = String.fromCharCode(codePoint);
      for (final wide in ['中', 'あ', '가', '각', '\u1100', '\u{1f600}']) {
        expect('$base$wide'.characters.length, 2,
            reason: '$wide after ${hex(codePoint)}');
      }
    }
  });

  test('isGraphemeControl matches segmentation for every code point', () {
    // GB4: only after a control does a combining mark start a new grapheme.
    for (final codePoint in allCodePoints()) {
      final breaks =
          '${String.fromCharCode(codePoint)}\u0301'.characters.length == 2;
      expect(isGraphemeControl(codePoint), breaks, reason: hex(codePoint));
    }
  });

  test('a mark zeroWidthExtends or isIndicVowelSign accepts joins any base',
      () {
    // The claim the mark shortcut in Buffer._joinsPreviousGrapheme rests on:
    // GB9, against a base of every class, Prepend and L included. Only a
    // control base (GB4) keeps it out.
    var accepted = 0;
    for (final codePoint in allCodePoints()) {
      final width = unicodeV11.wcwidth(codePoint);
      if (!(width == 0 && zeroWidthExtends(codePoint) ||
          width == 1 && isIndicVowelSign(codePoint))) {
        continue;
      }
      accepted++;
      final char = String.fromCharCode(codePoint);
      for (final base in [...otherBases, '\u06dd', '\u1100', 'e\u0301']) {
        final expected = base == '\u2028' ? 2 : 1;
        expect('$base$char'.characters.length, expected,
            reason: '${hex(codePoint)} after ${hex(base.runes.first)}');
      }
    }
    expect(accepted, greaterThan(900));

    // The emoji modifiers too, which are wide: Buffer._joinsPreviousGrapheme
    // joins them to a valid emoji base on the same grounds.
    for (var codePoint = 0x1f3fb; codePoint <= 0x1f3ff; codePoint++) {
      final char = String.fromCharCode(codePoint);
      for (final base in [...otherBases, '\u{1f44d}', '\u{1f44d}\ufe0f']) {
        final expected = base == '\u2028' ? 2 : 1;
        expect('$base$char'.characters.length, expected,
            reason: '${hex(codePoint)} after ${hex(base.runes.first)}');
      }
    }
  });

  test('isConjunctLinker matches segmentation for every code point', () {
    // GB9c joins two consonants across a linker and across nothing else.
    for (final codePoint in allCodePoints()) {
      final char = String.fromCharCode(codePoint);
      final joins = '\u0915$char\u0915'.characters.length == 1;
      expect(isConjunctLinker(codePoint), joins, reason: hex(codePoint));
    }
  });

  test('a width-1 letter of isNarrowLetter joins only by GB9b or GB9c', () {
    // The claim the letter shortcut in Buffer._joinsPreviousGrapheme rests
    // on: after a cluster of every other kind - lone bases of every class,
    // Hangul L included, and clusters ending in a mark, a SpacingMark, a
    // jamo T or ZWJ after an emoji - every such letter starts a new grapheme.
    var accepted = 0;
    for (final codePoint in allCodePoints()) {
      if (unicodeV11.wcwidth(codePoint) != 1) continue;
      if (!isNarrowLetter(codePoint)) continue;
      accepted++;
      final char = String.fromCharCode(codePoint);
      for (final cluster in [
        ...otherBases,
        '\u1100',
        'e\u0301',
        '\u0915\u093f',
        '\u0628\u064e',
        '\u1100\u1161\u11a8',
        '\u{1f600}\u200d',
        '\u{1f1e6}\u{1f1e6}',
      ]) {
        expect('$cluster$char'.characters.length, cluster.characters.length + 1,
            reason: '${hex(codePoint)} after ${hex(cluster.runes.last)}');
      }
    }
    expect(accepted, greaterThan(1500));
  });
}
