import 'package:xterm3/src/core/escape/handler.dart';

/// An [EscapeTextHandler] that also takes runs holding wide characters.
///
/// [EscapeTextHandler.writeText] is only ever given code units that each fill
/// one cell, and handlers written against it rely on that. A handler that
/// implements this interface as well is given runs that also hold
/// `isWideRunUnit` code units, each of which fills two cells, through
/// [writeMixedWidthText] instead. Not exported: `Terminal` is the one
/// implementation.
abstract interface class MixedWidthTextHandler implements EscapeTextHandler {
  void writeMixedWidthText(String text, int start, int end);
}
