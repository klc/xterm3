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
  return codeUnit <= 0x590;
}
