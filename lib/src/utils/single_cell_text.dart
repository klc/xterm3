import 'dart:typed_data';

import 'package:xterm3/src/utils/unicode_v11.dart';

/// What [runClasses] holds for a BMP code unit.
const runClassOther = 0;
const runClassSingleCell = 1;
const runClassWide = 2;

/// The [runClassSingleCell] or [runClassWide] class of every BMP code unit,
/// [singleCellPrintableByRange] or [wideRunUnitByRange] answered once each.
///
/// The parser classifies every code unit of a run, in its scan or as it
/// carries the run on, and the range chains took a dozen or more compares
/// for the alphabets past Latin-1 and for CJK; a load costs the same for all
/// of them. Loops read it through a local, which keeps the
/// lazy-initialisation check of the field out of them.
final Uint8List runClasses = _buildRunClasses();

Uint8List _buildRunClasses() {
  final classes = Uint8List(0x10000);
  for (var codeUnit = 0; codeUnit < 0x10000; codeUnit++) {
    if (singleCellPrintableByRange(codeUnit)) {
      classes[codeUnit] = runClassSingleCell;
    } else if (wideRunUnitByRange(codeUnit)) {
      classes[codeUnit] = runClassWide;
    }
  }
  return classes;
}

/// Whether [codeUnit] can be written straight into one cell, without
/// consulting the width table or the grapheme cluster rules.
///
/// Two properties have to hold for every code unit in the set:
///
///  * It is a spacing character of width 1, so one code unit is one cell.
///  * It cannot continue the preceding grapheme cluster, so a run of them can
///    be written without asking whether each one joins what came before.
///
/// The ranges below are the ones where both hold and that ordinary text is
/// actually made of: ASCII, Latin-1, Latin Extended-A and B, IPA and spacing
/// modifiers, Greek, Cyrillic, Armenian. Everything in them has
/// Grapheme_Cluster_Break=Other; the classes that can extend a cluster
/// (Extend, SpacingMark, ZWJ, regional indicators, emoji modifiers, Hangul V
/// and T) all live outside them. The two holes are the combining blocks that
/// sit inside the range - U+0300..U+036F and U+0483..U+0489 - and U+00AD SOFT
/// HYPHEN, which is width 0.
///
/// Past the alphabets come the symbols a terminal draws with rather than
/// writes with: dashes, quotes and bullets (U+2010..U+2027), box drawing and
/// block elements (U+2500..U+259F) and braille (U+2800..U+28FF). They are
/// width 1 and Grapheme_Cluster_Break=Other as well, and a TUI's borders,
/// bars and graphs are made of nothing else - left out, each one took the
/// per-code-point path and a full grapheme segmentation, 27 times slower
/// than the run it now joins.
///
/// Wide scripts are absent: they take two cells each. [isWideRunUnit] is the
/// set of them that can be written in a run all the same.
///
/// Read from [runClasses], past ASCII: printable ASCII is answered by the two
/// compares the range chain began with, cheaper than a load.
@pragma('vm:prefer-inline')
bool isSingleCellPrintable(int codeUnit) {
  if (codeUnit < 0x7f) return codeUnit >= 0x20;
  return codeUnit <= 0xffff && runClasses[codeUnit] == runClassSingleCell;
}

/// The ranges [isSingleCellPrintable] is defined by, built into [runClasses].
bool singleCellPrintableByRange(int codeUnit) {
  if (codeUnit >= 0x20 && codeUnit <= 0x7e) return true;
  if (codeUnit < 0xa0) return false;
  if (codeUnit == 0xad) return false;
  if (codeUnit < 0x300) return true;
  if (codeUnit < 0x370) return false;
  if (codeUnit < 0x483) return true;
  if (codeUnit < 0x48a) return false;
  if (codeUnit <= 0x590) return true;
  if (codeUnit < 0x2010) return false;
  if (codeUnit <= 0x2027) return true;
  if (codeUnit < 0x2500) return false;
  if (codeUnit <= 0x259f) return true;
  return codeUnit >= 0x2800 && codeUnit <= 0x28ff;
}

/// Whether [codeUnit] can be written into two cells - a lead and a
/// placeholder - inside a run of [isSingleCellPrintable] text, without
/// consulting the width table or the grapheme cluster rules.
///
/// The same two properties as [isSingleCellPrintable], with width 2: every
/// code unit here is a spacing character of width 2, and neither it nor
/// anything [isSingleCellPrintable] accepts can continue a cluster that ends
/// in one of them, or in an [isSingleCellPrintable] character. Hangul
/// syllables do continue a cluster that ends in a leading jamo (GB6), and
/// anything here continues one that ends in Prepend or, for the pictographs,
/// a ZWJ (GB9b, GB11) - but no run character is any of those, so only the
/// first unit of a run, whose cell before may be one, has to be checked.
///
/// Taken are the CJK punctuation, kana, bopomofo, Hangul compatibility
/// jamo, CJK ideographs (Extension A and the unified block), Hangul
/// syllables, compatibility ideographs, the vertical and small form variants
/// and the fullwidth forms. Left out inside those stretches: the tone marks
/// U+302A..U+302F and the voicing marks U+3099..U+309A (Extend), U+303F
/// (width 1) and U+3164 HANGUL FILLER (width 0).
@pragma('vm:prefer-inline')
bool isWideRunUnit(int codeUnit) {
  return codeUnit >= 0x3000 &&
      codeUnit <= 0xffff &&
      runClasses[codeUnit] == runClassWide;
}

/// The ranges [isWideRunUnit] is defined by, built into [runClasses].
bool wideRunUnitByRange(int codeUnit) {
  if (codeUnit < 0x3000) return false;
  if (codeUnit < 0x4e00) {
    if (codeUnit <= 0x3029) return true;
    if (codeUnit < 0x3030) return false;
    if (codeUnit <= 0x303e) return true;
    if (codeUnit < 0x3041) return false;
    if (codeUnit <= 0x3096) return true;
    if (codeUnit < 0x309b) return false;
    if (codeUnit <= 0x30ff) return true;
    if (codeUnit < 0x3105) return false;
    if (codeUnit <= 0x312f) return true;
    if (codeUnit < 0x3131) return false;
    if (codeUnit <= 0x318e) return codeUnit != 0x3164;
    return codeUnit >= 0x3400 && codeUnit <= 0x4dbf;
  }
  if (codeUnit <= 0x9fff) return true;
  if (codeUnit < 0xac00) return false;
  if (codeUnit <= 0xd7a3) return true;
  if (codeUnit < 0xf900) return false;
  if (codeUnit <= 0xfaff) return true;
  if (codeUnit < 0xfe30) return false;
  if (codeUnit <= 0xfe6b) {
    return codeUnit != 0xfe53 && codeUnit != 0xfe67;
  }
  if (codeUnit < 0xff01) return false;
  if (codeUnit <= 0xff60) return true;
  return codeUnit >= 0xffe0 && codeUnit <= 0xffe6;
}

/// Whether [codePoint], above the BMP, can be written into two cells inside a
/// text run, as [isWideRunUnit] code units are: an emoji (Extended_
/// Pictographic) of width 2.
///
/// No run character continues a cluster that ends in one, and one continues
/// a cluster only after Prepend or ExtPict Extend* ZWJ (GB9b, GB11) - neither
/// of which a run character is. The marks that do attach to an emoji - skin
/// tones, VS16, ZWJ - are no run characters, so a run stops before them and
/// they take the per-character path as before.
bool isWideRunEmoji(int codePoint) {
  if (codePoint < 0x1f000) return false;
  // The emoji blocks most text holds, first; skin tones (U+1F3FB..U+1F3FF)
  // fall between the first two and are turned away as cheaply.
  if (codePoint >= 0x1f300 && codePoint <= 0x1f64f) {
    if (codePoint >= 0x1f3fb && codePoint <= 0x1f3ff) return false;
  } else if (codePoint < 0x1f680 || codePoint > 0x1faff) {
    if (codePoint >= 0x1f1e6 && codePoint <= 0x1f1ff) return false;
  }
  return isExtendedPictographic(codePoint) &&
      unicodeV11.wcwidth(codePoint) == 2;
}

/// Whether [codePoint] is Extended_Pictographic, the property GB11 joins
/// across a ZWJ: emoji, and the symbols that have an emoji form.
///
/// The ranges are the ones the grapheme segmenter (`characters`) uses; a test
/// checks every code point against it. None of them is Extend, so nothing in
/// here continues a cluster on its own - only after Prepend (GB9b) or after
/// ExtPict Extend* ZWJ (GB11).
bool isExtendedPictographic(int codePoint) {
  if (codePoint < 0xa9) return false;
  if (codePoint >= 0x1f000) {
    return switch (codePoint) {
      <= 0x1f0ff || >= 0x1f10d && <= 0x1f10f || 0x1f12f => true,
      >= 0x1f16c && <= 0x1f171 || >= 0x1f17e && <= 0x1f17f || 0x1f18e => true,
      >= 0x1f191 && <= 0x1f19a || >= 0x1f1ad && <= 0x1f1e5 => true,
      >= 0x1f201 && <= 0x1f20f || 0x1f21a || 0x1f22f => true,
      >= 0x1f232 && <= 0x1f23a || >= 0x1f23c && <= 0x1f23f => true,
      >= 0x1f249 && <= 0x1f3fa || >= 0x1f400 && <= 0x1f53d => true,
      >= 0x1f546 && <= 0x1f64f || >= 0x1f680 && <= 0x1f6ff => true,
      >= 0x1f774 && <= 0x1f77f || >= 0x1f7d5 && <= 0x1f7ff => true,
      >= 0x1f80c && <= 0x1f80f || >= 0x1f848 && <= 0x1f84f => true,
      >= 0x1f85a && <= 0x1f85f || >= 0x1f888 && <= 0x1f88f => true,
      >= 0x1f8ae && <= 0x1f8ff || >= 0x1f90c && <= 0x1f93a => true,
      >= 0x1f93c && <= 0x1f945 || >= 0x1f947 && <= 0x1faff => true,
      >= 0x1fc00 && <= 0x1fffd => true,
      _ => false,
    };
  }
  return switch (codePoint) {
    0xa9 || 0xae || 0x203c || 0x2049 || 0x2122 || 0x2139 => true,
    >= 0x2194 && <= 0x2199 || >= 0x21a9 && <= 0x21aa => true,
    >= 0x231a && <= 0x231b || 0x2328 || 0x2388 || 0x23cf => true,
    >= 0x23e9 && <= 0x23f3 || >= 0x23f8 && <= 0x23fa || 0x24c2 => true,
    >= 0x25aa && <= 0x25ab ||
    0x25b6 ||
    0x25c0 ||
    >= 0x25fb && <= 0x25fe =>
      true,
    >= 0x2600 && <= 0x2605 || >= 0x2607 && <= 0x2612 => true,
    >= 0x2614 && <= 0x2685 || >= 0x2690 && <= 0x2705 => true,
    >= 0x2708 && <= 0x2712 || 0x2714 || 0x2716 || 0x271d || 0x2721 => true,
    0x2728 || >= 0x2733 && <= 0x2734 || 0x2744 || 0x2747 || 0x274c => true,
    0x274e ||
    >= 0x2753 && <= 0x2755 ||
    0x2757 ||
    >= 0x2763 && <= 0x2767 =>
      true,
    >= 0x2795 && <= 0x2797 || 0x27a1 || 0x27b0 || 0x27bf => true,
    >= 0x2934 && <= 0x2935 || >= 0x2b05 && <= 0x2b07 => true,
    >= 0x2b1b && <= 0x2b1c || 0x2b50 || 0x2b55 || 0x3030 || 0x303d => true,
    0x3297 || 0x3299 => true,
    _ => false,
  };
}

/// Whether [codePoint] has Grapheme_Cluster_Break=Prepend: it joins whatever
/// follows it (GB9b), so a cell holding one can absorb the next character
/// even when that character is no mark.
bool isGraphemePrepend(int codePoint) {
  if (codePoint < 0x600 || codePoint > 0x11f02) return false;
  if (codePoint > 0xd4e && codePoint < 0x110bd) return false;
  return switch (codePoint) {
    >= 0x600 && <= 0x605 || 0x6dd || 0x70f || 0x890 || 0x891 => true,
    0x8e2 || 0xd4e || 0x110bd || 0x110cd || 0x111c2 || 0x111c3 => true,
    0x113d1 || 0x1193f || 0x11941 || 0x11a3a || 0x11d46 || 0x11f02 => true,
    >= 0x11a84 && <= 0x11a89 => true,
    _ => false,
  };
}

/// Whether [codePoint] is a Hangul leading consonant, Grapheme_Cluster_Break=L:
/// the only base a jamo or a precomposed syllable joins (GB6).
bool isHangulLeadingJamo(int codePoint) {
  return codePoint >= 0x1100 && codePoint <= 0x115f ||
      codePoint >= 0xa960 && codePoint <= 0xa97c;
}

/// Whether [codePoint], a code point already known to be zero width, extends
/// any grapheme cluster that does not end in a control: whether it has
/// Grapheme_Cluster_Break Extend or ZWJ (GB9).
///
/// This holds for the zero-width code points of whole stretches - the
/// combining diacritics and every script from Greek to Georgian, Ethiopic to
/// Mongolian - apart from the Prepend and control code points in them, Hangul
/// V and T (GB7, GB8), and the marks the width table already knows from a
/// newer Unicode version than the segmentation rules. Past U+2000 only the
/// joiners and the symbol diacritics are taken; everything else answers no
/// and goes to the slow path.
bool zeroWidthExtends(int codePoint) {
  if (codePoint < 0x300) return false;
  if (codePoint < 0x2000) {
    return switch (codePoint) {
      >= 0x600 && <= 0x605 || 0x61c || 0x70f || 0x890 || 0x891 => false,
      0x8e2 || 0xd4e || >= 0x1160 && <= 0x11ff || 0x180e => false,
      >= 0x1acf && <= 0x1aeb => false,
      _ => true,
    };
  }
  return codePoint == 0x200c ||
      codePoint == 0x200d ||
      codePoint >= 0x20d0 && codePoint <= 0x20ff;
}

/// Whether [codePoint], a code point already known to be width 1, is an Indic
/// dependent vowel sign that extends any grapheme cluster not ending in a
/// control: Grapheme_Cluster_Break SpacingMark or Extend (GB9a, GB9).
///
/// In the nine Indic blocks from Devanagari to Malayalam the vowel signs sit
/// at offsets 0x3E to 0x4C; at width 1 every one of them is such a mark. The
/// exceptions are the unassigned code points between them, which are width 1
/// and start a grapheme of their own.
bool isIndicVowelSign(int codePoint) {
  if (codePoint < 0x93e || codePoint > 0xd4c) return false;
  final offset = codePoint & 0x7f;
  if (offset < 0x3e || offset > 0x4c) return false;
  return switch (codePoint) {
    0x9c5 || 0x9c6 || 0x9c9 || 0x9ca || >= 0xa43 && <= 0xa46 => false,
    0xa49 || 0xa4a || 0xac6 || 0xaca || 0xb45 || 0xb46 || 0xb49 => false,
    0xb4a || >= 0xbc3 && <= 0xbc5 || 0xbc9 || 0xc45 || 0xc49 => false,
    0xcc5 || 0xcc9 || 0xd45 || 0xd49 => false,
    _ => true,
  };
}

/// Whether [codePoint] has Grapheme_Cluster_Break Control, CR or LF: nothing
/// joins a cluster across one (GB4, GB5).
bool isGraphemeControl(int codePoint) {
  if (codePoint < 0x20) return true;
  if (codePoint < 0x7f) return false;
  if (codePoint <= 0x9f) return true;
  if (codePoint < 0x2000) {
    return codePoint == 0xad || codePoint == 0x61c || codePoint == 0x180e;
  }
  return switch (codePoint) {
    0x200b || 0x200e || 0x200f || >= 0x2028 && <= 0x202e => true,
    >= 0x2060 && <= 0x206f || 0xfeff || >= 0xfff0 && <= 0xfffb => true,
    >= 0x13430 && <= 0x1343f || >= 0x1bca0 && <= 0x1bca3 => true,
    >= 0x1d173 && <= 0x1d17a || >= 0xe0000 && <= 0xe001f => true,
    >= 0xe0080 && <= 0xe00ff || >= 0xe01f0 && <= 0xe0fff => true,
    _ => false,
  };
}

/// Whether [codePoint], a code point already known to be width 1, is a letter
/// that extends no grapheme cluster and is no Hangul jamo, regional indicator
/// or Extended_Pictographic code point: it joins the cluster before it only
/// through GB9b or GB9c.
///
/// Taken are whole alphabets that keep their marks at width 0 - Hebrew to NKo,
/// Thai and Lao but for SARA AM, Georgian, the Latin and Greek extended blocks
/// - and, in each of the ten Indic blocks, the stretch of independent vowels
/// and consonants (offsets 0x04 to 0x39) before the dependent vowel signs,
/// several of which are width 1 SpacingMarks.
bool isNarrowLetter(int codePoint) {
  if (codePoint < 0x590) return false;
  if (codePoint < 0x8ca) return true;
  if (codePoint < 0x900) return false;
  if (codePoint < 0xe00) {
    final offset = codePoint & 0x7f;
    return offset >= 0x04 && offset < 0x3a;
  }
  if (codePoint < 0xf00) return codePoint != 0xe33 && codePoint != 0xeb3;
  if (codePoint < 0x10a0) return false;
  if (codePoint < 0x1100) return true;
  return codePoint >= 0x1e00 && codePoint < 0x2000;
}

/// Whether [codePoint] is an Indic conjunct linker, Indic_Conjunct_Break=
/// Linker: the virama that GB9c joins two consonants across.
bool isConjunctLinker(int codePoint) {
  return switch (codePoint) {
    0x94d || 0x9cd || 0xacd || 0xb4d || 0xc4d || 0xd4d => true,
    _ => false,
  };
}
