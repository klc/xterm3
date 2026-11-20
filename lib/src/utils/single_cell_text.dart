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
/// Wide scripts are deliberately absent: CJK is width 2 and needs the
/// per-code-point path that allocates a lead and a placeholder.
bool isSingleCellPrintable(int codeUnit) {
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
