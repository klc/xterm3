import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:xterm3/src/core/buffer/cell_offset.dart';
import 'package:xterm3/src/core/buffer/line.dart';
import 'package:xterm3/src/core/buffer/range.dart';
import 'package:xterm3/src/core/buffer/range_block.dart';
import 'package:xterm3/src/core/buffer/range_line.dart';
import 'package:xterm3/src/core/charset.dart';
import 'package:xterm3/src/core/cell.dart';
import 'package:xterm3/src/core/cursor.dart';
import 'package:xterm3/src/core/reflow.dart';
import 'package:xterm3/src/core/state.dart';
import 'package:xterm3/src/utils/circular_buffer.dart';
import 'package:xterm3/src/utils/single_cell_text.dart';
import 'package:xterm3/src/utils/unicode_v11.dart';

class Buffer {
  final TerminalState terminal;

  final int maxLines;

  final bool isAltBuffer;

  /// Characters that break selection when calling [getWordBoundary]. If null,
  /// defaults to [defaultWordSeparators].
  final Set<int>? wordSeparators;

  /// Called after a line is dropped from the front of [lines] because
  /// scrollback overflowed.
  final void Function(BufferLine line)? onLineEvicted;

  Buffer(
    this.terminal, {
    required this.maxLines,
    required this.isAltBuffer,
    this.wordSeparators,
    this.onLineEvicted,
    Charset? charset,
  }) : charset = charset ?? Charset() {
    for (int i = 0; i < terminal.viewHeight; i++) {
      lines.push(_newEmptyLine());
    }

    resetVerticalMargins();
    resetHorizontalMargins();
  }

  int _cursorX = 0;

  int _cursorY = 0;

  // The constructor sets the margins. Not late: a late field checks that it
  // was set on every read, and the margins are read for every line.
  int _marginTop = 0;

  int _marginBottom = 0;

  int _marginLeft = 0;

  int _marginRight = 0;

  var _savedCursorX = 0;

  var _savedCursorY = 0;

  var _savedPendingWrap = false;

  var _savedOriginMode = false;

  final _savedCursorStyle = CursorStyle();

  /// The live G0-G3 designations and GL. A terminal hands both of its
  /// buffers the same one, as in xterm: only the DECSC copy is per screen.
  final Charset charset;

  final _savedCharset = Charset();

  /// Width of the viewport in columns. Also the index of the last column.
  int get viewWidth => terminal.viewWidth;

  /// Height of the viewport in rows. Also the index of the last line.
  int get viewHeight => terminal.viewHeight;

  /// lines of the buffer. the length of [lines] should always be equal or
  /// greater than [viewHeight].
  late final lines = IndexAwareCircularBuffer<BufferLine>(
    max(maxLines, terminal.viewHeight),
    onEvict: _onLineEvicted,
  );

  /// Cell storage taken from the last line that fell off a large scrollback,
  /// cleared, for the next new line to use instead of allocating.
  ///
  /// A field rather than a list of spares, deliberately: what comes out of a
  /// field assigned only from [BufferLine]'s own storage is known to the
  /// compiler to be the same concrete typed-data class. Taken out of a
  /// `List<Uint32List>`, a store could be any [Uint32List] - a view, say -
  /// and every cell read and write in the package paid a type check for it:
  /// 7-9% on output that never recycled a line.
  Uint32List? _spareStorage;

  /// Scrollbacks at least this many cells large (lines times columns) recycle
  /// the storage of the lines they evict.
  ///
  /// A line that falls off a large scrollback has lived long enough for its
  /// storage to have left the young generation, and so does each new line's,
  /// at a cost the example app pays at about twice the command-line rate:
  /// reusing the evicted storage, cleared, saves that. A line that falls off
  /// a small scrollback - or the alternate screen, or a terminal with none -
  /// dies young, where allocating is close to free and clearing is the
  /// dearer of the two. Measured in the example app at 100 columns, recycling
  /// lost 12-20% up to 3000 lines, broke even at 5000 and won 10-19% from
  /// 7000; the threshold is that point, as cells, on the assumption that the
  /// crossover follows the bytes the scrollback keeps. Those numbers were
  /// taken while a store was still cleared word by word; clearing has since
  /// become a block copy, so the crossover is likely lower and not measured.
  ///
  /// The cost is memory. A recycled store goes to the next line whatever its
  /// size, and a line grows a store that is too small for it to the full
  /// width, so once the scrollback has filled, every line's storage tends to
  /// the full width - the size every line had before lines were sized to
  /// their text. 10000 lines at 100 columns hold 19.5 MiB of cells either way,
  /// against 10.8-14.3 MiB for the same output without recycling. Handing a
  /// store only to a line that would have allocated one of exactly its size
  /// kept memory where it was and gave up most of the speed: ascii 6% faster
  /// instead of 19%, and nothing on output written in several runs a line,
  /// whose first store is too small and is grown.
  static const recycleThresholdCells = 700000;

  void _onLineEvicted(BufferLine line) {
    // The terminal reads the evicted line's hyperlinks first.
    onLineEvicted?.call(line);
    if (_spareStorage == null &&
        lines.maxLength * viewWidth >= recycleThresholdCells) {
      _spareStorage = line.takeStorage();
    }
  }

  /// Total number of lines in the buffer. Always equal or greater than
  /// [viewHeight].
  int get height => lines.length;

  /// Horizontal position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorX => _cursorX.clamp(0, terminal.viewWidth - 1);

  /// Vertical position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorY => _cursorY;

  /// Index of the first line in the scroll region.
  int get marginTop => _marginTop;

  /// Index of the last line in the scroll region.
  int get marginBottom => _marginBottom;

  /// Index of the first column in the horizontal scroll region.
  int get marginLeft => _marginLeft;

  /// Index of the last column in the horizontal scroll region.
  int get marginRight => _marginRight;

  /// The number of lines above the viewport.
  int get scrollBack => height - viewHeight;

  /// Increments when terminal-originated actions should force the viewport to
  /// the bottom even if the user was previously scrolled up.
  int get forceScrollToBottomGeneration => _forceScrollToBottomGeneration;
  var _forceScrollToBottomGeneration = 0;

  /// Vertical position of the cursor relative to the top of the buffer,
  /// starting from 0.
  int get absoluteCursorY => _cursorY + scrollBack;

  /// Absolute index of the first line in the scroll region.
  int get absoluteMarginTop => _marginTop + scrollBack;

  /// Absolute index of the last line in the scroll region.
  int get absoluteMarginBottom => _marginBottom + scrollBack;

  /// Writes data to the _terminal. Terminal sequences or special characters are
  /// not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.write]
  void write(String text) {
    for (var char in text.runes) {
      writeChar(char);
    }
  }

  void writeAscii(String text, int start, int end) {
    if (terminal.insertMode || !terminal.autoWrapMode || !charset.isAscii) {
      for (var index = start; index < end; index++) {
        writeChar(text.codeUnitAt(index));
      }
      return;
    }

    // Most runs are a few cells and fit in one pass, so what each pass reads
    // is paid per run: the style once, the right limit once unless a wrap
    // moved the cursor under a different one.
    final style = terminal.cursor;
    while (start < end) {
      var rightLimit = _rightLimit;
      if (_cursorX >= rightLimit) {
        _wrapInput();
        rightLimit = _rightLimit;
      }

      final count = min(end - start, rightLimit - _cursorX);
      currentLine.setAsciiCells(_cursorX, text, start, count, style);
      _cursorX += count;
      start += count;
    }
  }

  /// [writeAscii] for a run that also holds [isWideRunUnit] code units and
  /// [isWideRunEmoji] surrogate pairs, each written as a width-2 lead and a
  /// width-0 placeholder.
  ///
  /// Each stretch of the run that fits on the line is written in one call.
  /// What has to decide something goes through [writeChar] one unit at a
  /// time, exactly as before: a wide first unit that continues the cluster in
  /// the cell before the run (see [isWideRunUnit]), and a wide unit that
  /// meets the right margin - with one column left, where it pads and wraps
  /// or is dropped, or with none, where it wraps. None of them comes up more
  /// than once a line.
  void writeMixedWidth(String text, int start, int end) {
    if (terminal.insertMode || !terminal.autoWrapMode || !charset.isAscii) {
      while (start < end) {
        start = _writeCharAt(text, start);
      }
      return;
    }

    // Of what [writeChar] does with a wide first unit, only the join check
    // can come out differently from writing the unit in the run - the loop
    // below hands it the margin cases - so that is all that is asked here.
    // The rest, a width lookup, the margin checks and two cell writes of its
    // own, was paid on every line of CJK text.
    final first = text.codeUnitAt(start);
    if (!isSingleCellPrintable(first) &&
        terminal.graphemeClusterMode &&
        _joinsPreviousGrapheme(
            _isHighSurrogate(first)
                ? 0x10000 +
                    ((first - 0xd800) << 10) +
                    (text.codeUnitAt(start + 1) - 0xdc00)
                : first,
            2)) {
      start = _writeCharAt(text, start);
    }

    final style = terminal.cursor;
    final classes = runClasses;
    while (start < end) {
      var rightLimit = _rightLimit;
      if (_cursorX >= rightLimit) {
        // [writeChar] asks whether a wide character joins the cell before
        // the cursor before it wraps, and that cell can still be one the run
        // has not written: the first unit may have written nothing (a join
        // that could not widen the cluster at width 1, or a drop). A narrow
        // unit joins nothing, so wrapping first is what [writeChar] does too.
        if (!isSingleCellPrintable(text.codeUnitAt(start))) {
          start = _writeCharAt(text, start);
          continue;
        }
        _wrapInput();
        rightLimit = _rightLimit;
      }

      // Everything in the run that is not single-cell is two cells wide: an
      // [isWideRunUnit] code unit or an [isWideRunEmoji] surrogate pair.
      var x = _cursorX;
      var index = start;
      var wide = false;
      while (index < end) {
        final codeUnit = text.codeUnitAt(index);
        if (classes[codeUnit] == runClassSingleCell) {
          if (x >= rightLimit) break;
          x++;
          index++;
        } else {
          if (x + 2 > rightLimit) break;
          wide = true;
          x += 2;
          // Written out: as a call it stayed one, once per wide unit.
          index += codeUnit >= 0xd800 && codeUnit <= 0xdbff ? 2 : 1;
        }
      }

      if (index == start) {
        start = _writeCharAt(text, start);
        continue;
      }

      if (wide) {
        currentLine.setMixedWidthCells(
          _cursorX,
          text,
          start,
          index - start,
          x - _cursorX,
          style,
        );
      } else {
        currentLine.setAsciiCells(
          _cursorX,
          text,
          start,
          index - start,
          style,
        );
      }
      _cursorX = x;
      start = index;
    }
  }

  /// [writeChar] for the code point at [index] of [text], a surrogate pair
  /// included; returns the index after it.
  int _writeCharAt(String text, int index) {
    final codeUnit = text.codeUnitAt(index);
    if (_isHighSurrogate(codeUnit) && index + 1 < text.length) {
      final low = text.codeUnitAt(index + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        writeChar(0x10000 + ((codeUnit - 0xd800) << 10) + (low - 0xdc00));
        return index + 2;
      }
    }
    writeChar(codeUnit);
    return index + 1;
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xd800 && codeUnit <= 0xdbff;

  /// Writes a single character to the _terminal. Escape sequences or special
  /// characters are not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.writeChar]
  int writeChar(int codePoint) {
    codePoint = charset.translate(codePoint);

    final cellWidth = unicodeV11.wcwidth(codePoint);
    if (terminal.graphemeClusterMode &&
        (codePoint == 0xFE0E || codePoint == 0xFE0F)) {
      if (_previousSupportsEmojiVariation(codePoint) &&
          _resizePreviousGrapheme(codePoint)) {
        _addCombiningCharacter(codePoint);
      }
      return cellWidth;
    }
    if (cellWidth == 0) {
      if (!terminal.graphemeClusterMode) {
        _addCombiningCharacter(codePoint);
      } else if (_joinsPreviousGrapheme(codePoint, cellWidth)) {
        _joinLine.addCombiningCharacterTo(
            _joinIndex, _joinCombining, codePoint);
      }
      return cellWidth;
    }
    if (cellWidth < 0) return cellWidth;
    // Nothing [isSingleCellPrintable] accepts can continue the preceding
    // grapheme cluster - see the same cut in [_joinsPreviousGrapheme] - so
    // neither check below can return true, and both of them read cells and
    // combining strings to find that out. Skipping them outright is what keeps
    // ordinary alphabetic text off the cluster machinery entirely.
    final mayJoinPreviousGrapheme =
        terminal.graphemeClusterMode && !isSingleCellPrintable(codePoint);
    if (mayJoinPreviousGrapheme && _joinRegionalIndicator(codePoint)) {
      return cellWidth;
    }
    if (mayJoinPreviousGrapheme &&
        _joinsPreviousGrapheme(codePoint, cellWidth)) {
      final line = _joinLine;
      final previousWidth = _joinedPreviousGraphemeWidth(codePoint, cellWidth);
      // Only widening the cell moves it, or the cursor; a cell that is wide
      // already - an emoji the next code point of its sequence joins - takes
      // the code point where [_joinsPreviousGrapheme] found it.
      if (previousWidth == 2 && line.getWidth(_joinIndex) != 2) {
        if (!_setPreviousGraphemeWidth(2)) return cellWidth;
        _addCombiningCharacter(codePoint);
        return cellWidth;
      }
      line.addCombiningCharacterTo(_joinIndex, _joinCombining, codePoint);
      return cellWidth;
    }

    final rightLimit = _rightLimit;

    if (_cursorX >= rightLimit) {
      if (terminal.autoWrapMode) {
        _wrapInput();
      } else {
        _cursorX = rightLimit - 1;
      }
    }

    if (cellWidth > rightLimit - _marginLeft) {
      _cursorX = rightLimit;
      return cellWidth;
    }

    if (cellWidth == 2 && _cursorX == rightLimit - 1) {
      if (!terminal.autoWrapMode) {
        _cursorX = rightLimit;
        return cellWidth;
      }

      currentLine.setCell(_cursorX, 0, 1, terminal.cursor);
      _cursorX = rightLimit;
      _wrapInput();
    }

    final line = currentLine;
    if (terminal.insertMode) {
      line.insertCells(_cursorX, cellWidth, terminal.cursor);
    }
    if (!terminal.insertMode) {
      line.clearWideCellAt(_cursorX, terminal.cursor);
      if (cellWidth == 2) {
        line.clearWideCellAt(_cursorX + 1, terminal.cursor);
      }
    }
    line.setCell(_cursorX, codePoint, cellWidth, terminal.cursor);

    if (cellWidth == 2) {
      line.setCell(_cursorX + 1, 0, 0, terminal.cursor);
    }

    _cursorX += cellWidth;
    return cellWidth;
  }

  void _addCombiningCharacter(int codePoint) {
    if (_cursorX == 0) return;

    final line = currentLine;
    var index = min(_cursorX - 1, viewWidth - 1);
    if (index > 0 && line.getWidth(index) == 0) {
      index--;
    }
    if (line.getCodePoint(index) == 0) return;
    line.addCombiningCharacter(index, codePoint);
  }

  bool _resizePreviousGrapheme(int variationSelector) {
    final desiredWidth = switch (variationSelector) {
      0xFE0F => 2,
      0xFE0E => 1,
      _ => null,
    };
    if (desiredWidth == null) return false;
    return _setPreviousGraphemeWidth(desiredWidth);
  }

  bool _previousSupportsEmojiVariation(int variationSelector) {
    final index = _previousCellIndex();
    if (index == null) return false;
    return _supportsEmojiVariation(
      currentLine.getCodePoint(index),
      variationSelector,
    );
  }

  bool _setPreviousGraphemeWidth(int desiredWidth) {
    final index = _previousCellIndex();
    // The line the cell is on, until a wrap below moves to the next one.
    final line = currentLine;
    if (index == null || line.getCodePoint(index) == 0) return false;

    final width = line.getWidth(index);
    if (desiredWidth == width) return true;
    if (desiredWidth > viewWidth) return false;

    if (desiredWidth == 2 && width == 1) {
      final rightLimit = _rightLimit;
      if (index + 1 >= rightLimit) {
        if (!terminal.autoWrapMode) return false;

        final sourceLine = line;
        final cellData = CellData.empty();
        sourceLine.getCellData(index, cellData);
        final combining = sourceLine.getCombiningCharacters(index);
        sourceLine.eraseCell(index, terminal.cursor);
        _cursorX = rightLimit;
        _wrapInput();
        final destinationIndex = _marginLeft;
        currentLine.setCellData(destinationIndex, cellData);
        currentLine.setWidth(destinationIndex, 2);
        if (combining != null) {
          for (final codePoint in combining.runes) {
            currentLine.addCombiningCharacter(destinationIndex, codePoint);
          }
        }
        currentLine.setCell(destinationIndex + 1, 0, 0, terminal.cursor);
        _cursorX = destinationIndex + 2;
        return true;
      }
      line.clearWideCellAt(index + 1, terminal.cursor);
      line.setWidth(index, 2);
      line.setCell(index + 1, 0, 0, terminal.cursor);
      if (_cursorX == index + 1) _cursorX++;
      return true;
    }

    if (desiredWidth == 1 && width == 2) {
      line.setWidth(index, 1);
      line.eraseCell(index + 1, terminal.cursor);
      if (_cursorX == index + 2) _cursorX--;
      return true;
    }

    return false;
  }

  int? _previousCellIndex() {
    if (_cursorX == 0) return null;
    var index = min(_cursorX - 1, viewWidth - 1);
    if (index > 0 && currentLine.getWidth(index) == 0) index--;
    return index;
  }

  /// The cell whose cluster the code point joins, once
  /// [_joinsPreviousGrapheme] has said it does: the cell
  /// [_addCombiningCharacter] would look up again.
  var _joinIndex = 0;

  /// The line holding [_joinIndex] and that cell's combining string, for the
  /// same caller: what joining the code point would read again otherwise.
  late BufferLine _joinLine;
  String? _joinCombining;

  /// [cellWidth] is `wcwidth(codePoint)`, which [writeChar] has already
  /// looked up - for an astral code point that is a binary search.
  bool _joinsPreviousGrapheme(int codePoint, int cellWidth) {
    // [_previousCellIndex] with one lookup of the line for it and the reads
    // below: [currentLine] goes through the circular buffer each time.
    if (_cursorX == 0) return false;
    final line = currentLine;
    var index = min(_cursorX - 1, viewWidth - 1);
    if (index > 0 && line.getWidth(index) == 0) index--;
    _joinIndex = index;
    final base = line.getCodePoint(index);
    if (base == 0) return false;
    final combining = line.getCombiningCharacters(index);
    _joinLine = line;
    _joinCombining = combining;

    final last = combining == null ? base : _lastRune(combining);

    // A wide code point never extends a cluster - the emoji modifiers are the
    // only wide Extend characters, and the check below owns them - and is
    // never a Hangul V or T, a regional indicator or an Indic consonant. That
    // leaves three rules that can join it to the cluster before, each decided
    // by the last code point stored: GB9b when that is Prepend, GB6 when it is
    // a leading jamo, GB11 when it is ZWJ. Every other case breaks, so CJK,
    // kana, emoji and Hangul syllables skip segmentation here, after a plain
    // base and after a cluster such as an emoji with VS16 or a modifier alike.
    // Neither check below can return true for such a code point: the Indic
    // one needs an Indic code point.
    if (cellWidth == 2 &&
        !_isEmojiModifier(codePoint) &&
        last != 0x200d &&
        !isGraphemePrepend(last) &&
        !isHangulLeadingJamo(last)) {
      return false;
    }

    // GB9, GB9a: a mark - Extend, ZWJ or SpacingMark - joins whatever comes
    // before it unless that is a control (GB4), so neither the cluster nor
    // the base matters, only the last code point stored - and a cell can end
    // in a control: U+2028 is width 1, and with mode 2027 off any zero-width
    // code point is stored. The two checks below agree: the Indic one only
    // ever returns true, and no emoji modifier is among these marks.
    if ((cellWidth == 0 && zeroWidthExtends(codePoint) ||
            cellWidth == 1 && isIndicVowelSign(codePoint)) &&
        !isGraphemeControl(last)) {
      return true;
    }

    if (_isWideIndicConjunct(base, combining, codePoint)) return true;

    if (_isEmojiModifier(codePoint)) {
      var modifierBase = base;
      if (combining != null) {
        for (final rune in combining.runes) {
          if (rune == 0x200D || rune == 0xFE0E || rune == 0xFE0F) continue;
          modifierBase = rune;
        }
      }
      if (_isEmojiModifierBase(modifierBase) == false) return false;
      // Past that check a modifier is a mark like the ones above: it has
      // Grapheme_Cluster_Break Extend and joins anything but a control (GB9).
      if (!isGraphemeControl(last)) return true;
    }

    // Almost all terminal output is ASCII, where a new printable code point
    // always starts a new grapheme. Avoid allocating strings on that path.
    if (base < 0x80 && codePoint < 0x80 && combining == null) return false;
    // The same shortcut, several alphabets wider: no code point that
    // [isSingleCellPrintable] accepts can continue a grapheme cluster, and
    // `combining == null` rules out a cluster that ends in ZWJ. Without this,
    // one accented letter in a line - `ö` in Turkish, every letter of a
    // Cyrillic one - drops the characters after it into grapheme
    // segmentation, at three string allocations each.
    if (combining == null && isSingleCellPrintable(codePoint)) return false;
    // A letter of [isNarrowLetter] extends nothing and is no Hangul jamo,
    // regional indicator or Extended_Pictographic code point, so of the rules
    // that join a character to the cluster before it only two are left: GB9b,
    // when the cluster ends in a Prepend code point, and GB9c, when the letter
    // is an Indic consonant and the cluster holds a conjunct linker. Without
    // either, it starts a new grapheme. This comes after the Indic conjunct
    // check above, which can join a pair that GB9c does not.
    if (cellWidth == 1 &&
        isNarrowLetter(codePoint) &&
        !isGraphemePrepend(last) &&
        !_hasConjunctLinker(combining)) {
      return false;
    }

    // Regional indicators and Extended_Pictographic code points (emoji and
    // the symbols with an emoji form) extend nothing, so the rules that can
    // join one to the cluster before are few, and each is decided by the
    // cluster's last code points: GB9b after Prepend, GB12 and GB13 for a
    // regional indicator after an odd run of them, GB11 for a pictograph
    // after ExtPict Extend* ZWJ. Without these, every flag and every emoji
    // with a ZWJ or VS16 in it came down to segmentation, at three string
    // allocations a code point. They come after the exits above so that the
    // code points those settle - wide emoji among them - do not pay for them.
    // What they cannot decide - a cell holding a sequence the rules do not
    // expect, which mode 2027 switched off and on can leave behind - still
    // goes to segmentation.
    if (_isRegionalIndicator(codePoint)) {
      final joins = _regionalIndicatorJoins(base, combining, last);
      if (joins != null) return joins;
    } else if (isExtendedPictographic(codePoint)) {
      final joins = _pictographJoins(base, combining, last);
      if (joins != null) return joins;
    }

    // A lone low surrogate as the base has no high one before it to pair
    // with, so segmentation breaks after it - and package:characters throws
    // on a string that opens with one.
    if (base >= 0xdc00 && base <= 0xdfff) return false;

    final previous = String.fromCharCode(base) + (combining ?? '');
    final storedGraphemes = previous.characters;
    final character = String.fromCharCode(codePoint);
    final candidate = storedGraphemes.last + character;
    if (candidate.characters.length == 1) return true;
    if (storedGraphemes.length == 1) return false;

    final extensionCandidate = 'a$character';
    return extensionCandidate.characters.length == 1;
  }

  /// Whether a regional indicator joins the cluster `base + combining`, which
  /// ends in [last]; null where only segmentation can tell.
  static bool? _regionalIndicatorJoins(int base, String? combining, int last) {
    if (_isSurrogate(base)) return null;
    if (isGraphemePrepend(last)) return true;
    if (!_isRegionalIndicator(last)) return false;
    // One regional indicator: the second of a flag. Two: a flag, which a third
    // does not join.
    if (combining == null) return true;
    if (_isRegionalIndicator(base) && combining.length == 2) return false;
    return null;
  }

  /// Whether an Extended_Pictographic code point joins the cluster
  /// `base + combining`, which ends in [last]; null where only segmentation
  /// can tell.
  static bool? _pictographJoins(int base, String? combining, int last) {
    if (_isSurrogate(base)) return null;
    if (isGraphemePrepend(last)) return true;
    if (last != 0x200d) return false;
    if (combining == null) return null;
    // GB11: ExtPict Extend* ZWJ, with Extend narrowed to the marks emoji
    // sequences hold - variation selectors, skin tone modifiers, tags.
    // Walked back from the ZWJ a code unit at a time, pairing a low surrogate
    // with the high one before it as [String.runes] does: a list of the runes
    // cost an allocation for every pictograph of every ZWJ sequence.
    var end = combining.length - 1;
    while (end > 0) {
      var rune = combining.codeUnitAt(--end);
      if (rune >= 0xdc00 && rune <= 0xdfff && end > 0) {
        final lead = combining.codeUnitAt(end - 1);
        if (lead >= 0xd800 && lead <= 0xdbff) {
          end--;
          rune = 0x10000 + ((lead - 0xd800) << 10) + (rune - 0xdc00);
        }
      }
      if (!_isEmojiSequenceMark(rune)) {
        return isExtendedPictographic(rune) ? true : null;
      }
    }
    if (_isEmojiSequenceMark(base)) return null;
    return isExtendedPictographic(base) ? true : null;
  }

  /// `string.runes.last` without the [Runes] object: a low surrogate pairs
  /// with a high one before it, any other code unit stands for itself.
  static int _lastRune(String string) {
    final last = string.codeUnitAt(string.length - 1);
    if (last >= 0xdc00 && last <= 0xdfff && string.length > 1) {
      final lead = string.codeUnitAt(string.length - 2);
      if (lead >= 0xd800 && lead <= 0xdbff) {
        return 0x10000 + ((lead - 0xd800) << 10) + (last - 0xdc00);
      }
    }
    return last;
  }

  static bool _isEmojiSequenceMark(int codePoint) =>
      codePoint >= 0xfe00 && codePoint <= 0xfe0f ||
      _isEmojiModifier(codePoint) ||
      codePoint >= 0xe0020 && codePoint <= 0xe007f;

  /// A lone surrogate as a cell's base - only malformed UTF-16 puts one there
  /// - can pair with a lone low surrogate at the start of its combining
  /// string once the two are one string, as segmentation sees them. The rules
  /// above read the base and the combining string apart, so they leave such a
  /// cell to segmentation.
  static bool _isSurrogate(int codePoint) =>
      codePoint >= 0xd800 && codePoint <= 0xdfff;

  static bool _hasConjunctLinker(String? combining) {
    if (combining == null) return false;
    for (final rune in combining.runes) {
      if (isConjunctLinker(rune)) return true;
    }
    return false;
  }

  int _joinedPreviousGraphemeWidth(int codePoint, int cellWidth) {
    if (cellWidth > 0) return 2;

    final index = _previousCellIndex();
    if (index == null) return 1;

    final base = currentLine.getCodePoint(index);
    final combining = currentLine.getCombiningCharacters(index);
    if (_isWideIndicConjunct(base, combining, codePoint)) return 2;

    return 1;
  }

  static bool _isWideIndicConjunct(
    int base,
    String? combining,
    int codePoint,
  ) {
    if (!_isIndicCodePoint(base)) return false;
    if (!_isIndicCodePoint(codePoint)) return false;
    if (combining == null) return false;

    var hasVirama = false;
    var hasJoiner = false;
    for (final rune in combining.runes) {
      if (_isIndicVirama(rune)) {
        hasVirama = true;
        continue;
      }
      if (rune == 0x200D) {
        hasJoiner = true;
      }
    }

    return hasVirama && hasJoiner;
  }

  static bool _isIndicCodePoint(int codePoint) {
    return switch (codePoint) {
      >= 0x0900 && <= 0x097F => true,
      >= 0x0980 && <= 0x09FF => true,
      >= 0x0A00 && <= 0x0A7F => true,
      >= 0x0A80 && <= 0x0AFF => true,
      >= 0x0B00 && <= 0x0B7F => true,
      >= 0x0B80 && <= 0x0BFF => true,
      >= 0x0C00 && <= 0x0C7F => true,
      >= 0x0C80 && <= 0x0CFF => true,
      >= 0x0D00 && <= 0x0D7F => true,
      >= 0x0D80 && <= 0x0DFF => true,
      _ => false,
    };
  }

  static bool _isIndicVirama(int codePoint) {
    return switch (codePoint) {
      0x094D || 0x09CD || 0x0A4D || 0x0ACD => true,
      0x0B4D || 0x0BCD || 0x0C4D || 0x0CCD => true,
      0x0D4D || 0x0DCA => true,
      _ => false,
    };
  }

  static bool _isEmojiModifier(int codePoint) {
    return codePoint >= 0x1F3FB && codePoint <= 0x1F3FF;
  }

  static bool _isEmojiModifierBase(int codePoint) {
    return switch (codePoint) {
      0x261D || 0x26F9 || >= 0x270A && <= 0x270D => true,
      0x1F385 || >= 0x1F3C2 && <= 0x1F3C4 || 0x1F3C7 => true,
      >= 0x1F3CA && <= 0x1F3CC => true,
      >= 0x1F442 && <= 0x1F443 || >= 0x1F446 && <= 0x1F450 => true,
      >= 0x1F466 && <= 0x1F478 || 0x1F47C => true,
      >= 0x1F481 && <= 0x1F483 || >= 0x1F485 && <= 0x1F487 => true,
      0x1F48F || 0x1F491 || 0x1F4AA => true,
      >= 0x1F574 && <= 0x1F575 || 0x1F57A || 0x1F590 => true,
      >= 0x1F595 && <= 0x1F596 => true,
      >= 0x1F645 && <= 0x1F647 || >= 0x1F64B && <= 0x1F64F => true,
      0x1F6A3 || >= 0x1F6B4 && <= 0x1F6B6 => true,
      0x1F6C0 || 0x1F6CC || 0x1F90C || 0x1F90F || 0x1F918 => true,
      >= 0x1F919 && <= 0x1F91F || 0x1F926 => true,
      >= 0x1F930 && <= 0x1F939 || >= 0x1F93C && <= 0x1F93E => true,
      0x1F977 || >= 0x1F9B5 && <= 0x1F9B6 => true,
      >= 0x1F9B8 && <= 0x1F9B9 || 0x1F9BB => true,
      >= 0x1F9CD && <= 0x1F9CF || >= 0x1F9D1 && <= 0x1F9DD => true,
      >= 0x1FAC3 && <= 0x1FAC5 || >= 0x1FAF0 && <= 0x1FAF8 => true,
      _ => false,
    };
  }

  bool _joinRegionalIndicator(int codePoint) {
    if (!_isRegionalIndicator(codePoint)) return false;
    final index = _previousCellIndex();
    if (index == null) return false;
    final line = currentLine;
    if (!_isRegionalIndicator(line.getCodePoint(index)) ||
        line.getCombiningCharacters(index) != null ||
        line.getWidth(index) != 1) {
      return false;
    }

    if (!_setPreviousGraphemeWidth(2)) return false;
    final widenedIndex = _previousCellIndex();
    if (widenedIndex == null) return false;
    currentLine.addCombiningCharacter(widenedIndex, codePoint);
    return true;
  }

  static bool _isRegionalIndicator(int codePoint) {
    return codePoint >= 0x1F1E6 && codePoint <= 0x1F1FF;
  }

  static bool _supportsEmojiVariation(int codePoint, int variationSelector) {
    return switch (codePoint) {
      0x23 || 0x2A || >= 0x30 && <= 0x39 => true,
      0xA9 || 0xAE || 0x203C || 0x2049 || 0x2122 || 0x2139 => true,
      >= 0x2194 && <= 0x2199 || >= 0x21A9 && <= 0x21AA => true,
      >= 0x231A && <= 0x231B || 0x2328 || 0x23CF => true,
      >= 0x23E9 && <= 0x23F3 || >= 0x23F8 && <= 0x23FA => true,
      0x24C2 || >= 0x25AA && <= 0x25AB || 0x25B6 || 0x25C0 => true,
      >= 0x25FB && <= 0x25FE || >= 0x2600 && <= 0x2604 => true,
      0x260E || 0x2611 || >= 0x2614 && <= 0x2615 || 0x2618 || 0x261D => true,
      0x2620 || >= 0x2622 && <= 0x2623 || 0x2626 || 0x262A => true,
      >= 0x262E && <= 0x262F || >= 0x2638 && <= 0x263A => true,
      0x2640 || 0x2642 || >= 0x2648 && <= 0x2653 => true,
      >= 0x265F && <= 0x2660 || 0x2663 || >= 0x2665 && <= 0x2666 => true,
      0x2668 || 0x267B || >= 0x267E && <= 0x267F => true,
      >= 0x2692 && <= 0x2697 || 0x2699 || >= 0x269B && <= 0x269C => true,
      >= 0x26A0 && <= 0x26A1 || 0x26A7 || >= 0x26AA && <= 0x26AB => true,
      >= 0x26B0 && <= 0x26B1 || >= 0x26BD && <= 0x26BE => true,
      >= 0x26C4 && <= 0x26C5 || 0x26C8 || >= 0x26CE && <= 0x26CF => true,
      0x26D1 || >= 0x26D3 && <= 0x26D4 || >= 0x26E9 && <= 0x26EA => true,
      >= 0x26F0 && <= 0x26F5 || >= 0x26F7 && <= 0x26FA || 0x26FD => true,
      0x2702 || 0x2705 || >= 0x2708 && <= 0x270D || 0x270F => true,
      0x2712 || 0x2714 || 0x2716 || 0x271D || 0x2721 || 0x2728 => true,
      >= 0x2733 && <= 0x2734 || 0x2744 || 0x2747 || 0x274C || 0x274E => true,
      >= 0x2753 && <= 0x2755 || 0x2757 || >= 0x2763 && <= 0x2764 => true,
      >= 0x2795 && <= 0x2797 || 0x27A1 || 0x27B0 || 0x27BF => true,
      >= 0x2934 && <= 0x2935 || >= 0x2B05 && <= 0x2B07 => true,
      >= 0x2B1B && <= 0x2B1C || 0x2B50 || 0x2B55 => true,
      0x3030 || 0x303D || 0x3297 || 0x3299 => true,
      >= 0x1F000 && <= 0x1FAFF => variationSelector == 0xFE0F,
      _ => false,
    };
  }

  void _wrapInput() {
    index();
    // What setCursorX(_marginLeft) comes to, the left margin being at or left
    // of the right one.
    _cursorX = _marginLeft;
    currentLine.isWrapped = true;
  }

  /// The line at the current cursor position.
  BufferLine get currentLine {
    return lines[absoluteCursorY];
  }

  void backspace() {
    if (_cursorX == 0 && currentLine.isWrapped) {
      currentLine.isWrapped = false;
      moveCursor(viewWidth - 1, -1);
    } else if (_cursorX == viewWidth) {
      moveCursor(-2, 0);
    } else {
      moveCursor(-1, 0);
    }
  }

  /// Erases the viewport from the cursor position to the end of the buffer,
  /// including the cursor position.
  void eraseDisplayFromCursor({bool respectProtected = false}) {
    eraseLineFromCursor(respectProtected: respectProtected);

    for (var i = absoluteCursorY + 1; i < height; i++) {
      final line = lines[i];
      line.isWrapped = false;
      line.eraseRange(
        0,
        viewWidth,
        terminal.cursor,
        respectProtected: respectProtected,
      );
    }
  }

  /// Erases the viewport from the top-left corner to the cursor, including the
  /// cursor.
  void eraseDisplayToCursor({bool respectProtected = false}) {
    eraseLineToCursor(respectProtected: respectProtected);
    currentLine.isWrapped = false;

    for (var i = 0; i < _cursorY; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(
        0,
        viewWidth,
        terminal.cursor,
        respectProtected: respectProtected,
      );
    }
  }

  /// Erases the whole viewport.
  void eraseDisplay({bool respectProtected = false}) {
    _cancelPendingWrap();
    for (var i = 0; i < viewHeight; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(
        0,
        viewWidth,
        terminal.cursor,
        respectProtected: respectProtected,
      );
    }
    _forceScrollToBottomGeneration++;
  }

  /// Erases the line from the cursor to the end of the line, including the
  /// cursor position.
  void eraseLineFromCursor({bool respectProtected = false}) {
    _cancelPendingWrap();
    // Like xterm.js: the row stops continuing the previous one only when the
    // whole row is erased.
    if (_cursorX == 0) currentLine.isWrapped = false;
    currentLine.eraseRange(
      _cursorX,
      viewWidth,
      terminal.cursor,
      respectProtected: respectProtected,
    );
  }

  /// Erases the line from the start of the line to the cursor, including the
  /// cursor.
  void eraseLineToCursor({bool respectProtected = false}) {
    _cancelPendingWrap();
    currentLine.eraseRange(
      0,
      _cursorX + 1,
      terminal.cursor,
      respectProtected: respectProtected,
    );
  }

  /// Erases the line at the current cursor position.
  void eraseLine({bool respectProtected = false}) {
    _cancelPendingWrap();
    currentLine.isWrapped = false;
    currentLine.eraseRange(
      0,
      viewWidth,
      terminal.cursor,
      respectProtected: respectProtected,
    );
  }

  /// Erases [count] cells starting at the cursor position.
  void eraseChars(int count, {bool respectProtected = false}) {
    _cancelPendingWrap();
    final start = _cursorX;
    count = min(count, viewWidth - start);
    currentLine.eraseRange(
      start,
      start + count,
      terminal.cursor,
      respectProtected: respectProtected,
    );
  }

  void eraseRect(
    int top,
    int left,
    int bottom,
    int right, {
    bool respectProtected = false,
  }) {
    final rect = _normalizeRect(top, left, bottom, right);
    if (rect == null) return;

    for (var row = rect.top; row <= rect.bottom; row++) {
      lines[row + scrollBack].eraseRange(
        rect.left,
        rect.right + 1,
        terminal.cursor,
        respectProtected: respectProtected,
      );
    }
  }

  void fillRect(int char, int top, int left, int bottom, int right) {
    final rect = _normalizeRect(top, left, bottom, right);
    if (rect == null) return;
    if (unicodeV11.wcwidth(char) != 1 || _isSurrogate(char)) return;

    for (var row = rect.top; row <= rect.bottom; row++) {
      final line = lines[row + scrollBack];
      line.eraseRange(rect.left, rect.right + 1, terminal.cursor);
      for (var col = rect.left; col <= rect.right; col++) {
        line.setCell(col, char, 1, terminal.cursor);
      }
    }
  }

  void copyRect(
    int sourceTop,
    int sourceLeft,
    int sourceBottom,
    int sourceRight,
    int sourcePage,
    int destinationTop,
    int destinationLeft,
    int destinationPage,
  ) {
    if (sourcePage != 1 || destinationPage != 1) return;

    final sourceRect =
        _normalizeRect(sourceTop, sourceLeft, sourceBottom, sourceRight);
    if (sourceRect == null) return;

    final destinationRect = _normalizeRect(
      destinationTop,
      destinationLeft,
      destinationTop + sourceRect.bottom - sourceRect.top,
      destinationLeft + sourceRect.right - sourceRect.left,
    );
    if (destinationRect == null) return;

    final width = min(
      sourceRect.right - sourceRect.left + 1,
      destinationRect.right - destinationRect.left + 1,
    );
    final height = min(
      sourceRect.bottom - sourceRect.top + 1,
      destinationRect.bottom - destinationRect.top + 1,
    );
    if (width <= 0 || height <= 0) return;

    final copiedLines = <BufferLine>[];
    for (var row = 0; row < height; row++) {
      final sourceLine = lines[sourceRect.top + row + scrollBack];
      copiedLines.add(BufferLine(width)
        ..copyFrom(
          sourceLine,
          sourceRect.left,
          0,
          width,
        ));
    }

    for (var row = 0; row < height; row++) {
      final destinationLine = lines[destinationRect.top + row + scrollBack];
      destinationLine.copyFrom(
        copiedLines[row],
        0,
        destinationRect.left,
        width,
      );
    }
  }

  void changeRectAttributes(
    int top,
    int left,
    int bottom,
    int right,
    int attribute, {
    required bool rectangular,
  }) {
    _applyAttributeRect(
      top,
      left,
      bottom,
      right,
      (attrs) => _changeAttributes(attrs, attribute),
      rectangular: rectangular,
    );
  }

  void reverseRectAttributes(
    int top,
    int left,
    int bottom,
    int right,
    int attribute, {
    required bool rectangular,
  }) {
    _applyAttributeRect(
      top,
      left,
      bottom,
      right,
      (attrs) => attrs ^ _attributeMask(attribute),
      rectangular: rectangular,
    );
  }

  void _applyAttributeRect(
    int top,
    int left,
    int bottom,
    int right,
    int Function(int attrs) transform, {
    required bool rectangular,
  }) {
    final rect = _normalizeRect(top, left, bottom, right);
    if (rect == null) return;

    for (var row = rect.top; row <= rect.bottom; row++) {
      final line = lines[row + scrollBack];
      final rowStart = switch (rectangular || row == rect.top) {
        true => rect.left,
        false => _attributeRegionLeft,
      };
      final rowEnd = switch (rectangular || row == rect.bottom) {
        true => rect.right,
        false => _attributeRegionRight,
      };

      for (var col = rowStart; col <= rowEnd; col++) {
        line.setAttributes(col, transform(line.getAttributes(col)));
      }
    }
  }

  int _changeAttributes(int attrs, int attribute) {
    if (attribute == 0) return attrs & ~CellAttr.visualMask;
    return attrs | _attributeMask(attribute);
  }

  int _attributeMask(int attribute) {
    return switch (attribute) {
      1 => CellAttr.bold,
      4 => CellAttr.underline,
      5 => CellAttr.blink,
      7 => CellAttr.inverse,
      8 => CellAttr.invisible,
      9 => CellAttr.strikethrough,
      _ => 0,
    };
  }

  int get _attributeRegionLeft {
    return switch (terminal.originMode) {
      true => marginLeft,
      false => 0,
    };
  }

  int get _attributeRegionRight {
    return switch (terminal.originMode) {
      true => marginRight,
      false => viewWidth - 1,
    };
  }

  ({int top, int left, int bottom, int right})? _normalizeRect(
    int top,
    int left,
    int bottom,
    int right,
  ) {
    final topOffset = switch (terminal.originMode) {
      true => marginTop,
      false => 0,
    };
    final leftOffset = switch (terminal.originMode) {
      true => marginLeft,
      false => 0,
    };
    final bottomLimit = switch (terminal.originMode) {
      true => marginBottom,
      false => viewHeight - 1,
    };
    final rightLimit = switch (terminal.originMode) {
      true => marginRight,
      false => viewWidth - 1,
    };

    final normalizedTop =
        (topOffset + max(top, 1) - 1).clamp(0, bottomLimit).toInt();
    final normalizedLeft =
        (leftOffset + max(left, 1) - 1).clamp(0, rightLimit).toInt();
    final normalizedBottom =
        (topOffset + max(bottom, 1) - 1).clamp(0, bottomLimit).toInt();
    final normalizedRight =
        (leftOffset + max(right, 1) - 1).clamp(0, rightLimit).toInt();

    if (normalizedTop > normalizedBottom) return null;
    if (normalizedLeft > normalizedRight) return null;

    return (
      top: normalizedTop,
      left: normalizedLeft,
      bottom: normalizedBottom,
      right: normalizedRight,
    );
  }

  void scrollDown(int count) {
    if (_usesFullHorizontalMargins) {
      _scrollDownFullWidth(count);
      return;
    }

    final width = _marginRight - _marginLeft + 1;
    for (var i = absoluteMarginBottom; i >= absoluteMarginTop; i--) {
      if (i >= absoluteMarginTop + count) {
        lines[i].copyFrom(
          lines[i - count],
          _marginLeft,
          _marginLeft,
          width,
        );
      } else {
        lines[i].eraseRange(_marginLeft, _marginRight + 1, terminal.cursor);
      }
    }
  }

  void scrollUp(int count) {
    if (_usesFullHorizontalMargins) {
      _scrollUpFullWidth(count);
      return;
    }

    final width = _marginRight - _marginLeft + 1;
    for (var i = absoluteMarginTop; i <= absoluteMarginBottom; i++) {
      if (i <= absoluteMarginBottom - count) {
        lines[i].copyFrom(
          lines[i + count],
          _marginLeft,
          _marginLeft,
          width,
        );
      } else {
        lines[i].eraseRange(_marginLeft, _marginRight + 1, terminal.cursor);
      }
    }
  }

  void _scrollDownFullWidth(int count) {
    for (var i = absoluteMarginBottom; i >= absoluteMarginTop; i--) {
      if (i >= absoluteMarginTop + count) {
        lines.move(i - count, i);
      } else {
        lines[i] = _newScrolledLine();
      }
    }
  }

  void _scrollUpFullWidth(int count) {
    if (_canScrollUpByPushingLines) {
      final linesToPush = min(count, _marginBottom + 1);
      for (var i = 0; i < linesToPush; i++) {
        lines.push(_newScrolledLine());
        // Rows below the scroll region keep their place on screen.
        if (_marginBottom < viewHeight - 1) {
          for (var row = viewHeight - 1; row > _marginBottom; row--) {
            lines.move(row - 1 + scrollBack, row + scrollBack);
          }
          lines[absoluteMarginBottom] = _newScrolledLine();
        }
      }
      return;
    }

    for (var i = absoluteMarginTop; i <= absoluteMarginBottom; i++) {
      if (i <= absoluteMarginBottom - count) {
        lines.move(i + count, i);
      } else {
        lines[i] = _newScrolledLine();
      }
    }
  }

  /// Whether scrolling moves the top row into scrollback, like xterm does for
  /// a main-buffer scroll region that starts at the top of the screen.
  bool get _canScrollUpByPushingLines {
    if (isAltBuffer) return false;
    return _marginTop == 0;
  }

  /// https://vt100.net/docs/vt100-ug/chapter3.html#IND IND – Index
  ///
  /// ESC D
  ///
  /// [index] causes the active position to move downward one line without
  /// changing the column position. If the active position is at the bottom
  /// margin, a scroll up is performed.
  void index() {
    if (isInVerticalMargin) {
      if (!isInHorizontalMarginOrPendingWrap) return;
      if (_cursorY == _marginBottom) {
        // scrollUp() already pushes new lines onto the scrollback when the
        // region starts at the top of the viewport; inserting a line here
        // instead would leave a partial scroll region unscrolled and shift
        // every row below the bottom margin down.
        scrollUp(1);
      } else {
        // What moveCursorY(1) comes to here: inside the margins and above the
        // bottom one, there is no limit to meet.
        _cursorY++;
      }
      return;
    }

    // the cursor is not in the scrollable region
    if (_cursorY >= viewHeight - 1) {
      // we are at the bottom
      if (isAltBuffer) {
        scrollUp(1);
      } else {
        lines.push(_newScrolledLine());
      }
    } else {
      // there're still lines so we simply move cursor down.
      moveCursorY(1);
    }
  }

  void lineFeed() {
    index();
    if (terminal.lineFeedMode) {
      setCursorX(0);
    }
  }

  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  void reverseIndex() {
    if (isInVerticalMargin) {
      if (!isInHorizontalMarginOrPendingWrap) return;
      if (_cursorY == _marginTop) {
        scrollDown(1);
      } else {
        moveCursorY(-1);
      }
    } else {
      moveCursorY(-1);
    }
  }

  void backIndex() {
    if (_cursorX == 0) return;
    if (_cursorX == _marginLeft && isInVerticalMargin) {
      for (var row = absoluteMarginTop; row <= absoluteMarginBottom; row++) {
        lines[row].insertCells(
          _marginLeft,
          1,
          _blankCellStyle,
          _marginRight + 1,
        );
      }
      return;
    }
    moveCursorX(-1);
  }

  void forwardIndex() {
    if (_cursorX == viewWidth - 1) return;
    if (_cursorX == _marginRight && isInVerticalMargin) {
      for (var row = absoluteMarginTop; row <= absoluteMarginBottom; row++) {
        lines[row].removeCells(
          _marginLeft,
          1,
          _blankCellStyle,
          _marginRight + 1,
        );
      }
      return;
    }
    moveCursorX(1);
  }

  void cursorGoForward() {
    _cursorX = min(_cursorX + 1, _rightLimit);
  }

  void setCursorX(int cursorX) {
    final minimum = _minimumCursorX(cursorX);
    final maximum = _maximumCursorX(cursorX);
    _cursorX = cursorX < minimum
        ? minimum
        : cursorX > maximum
            ? maximum
            : cursorX;
  }

  void setCursorY(int cursorY) {
    _cursorY = cursorY.clamp(0, viewHeight - 1);
  }

  void moveCursorX(int offset) {
    if (offset < 0) {
      _moveCursorLeft(-offset);
      return;
    }

    setCursorX(_cursorX + offset);
  }

  void _moveCursorLeft(int count) {
    if (count <= 0) return;

    final wrapMode = _cursorLeftWrapMode;
    if (_isPendingWrap) {
      _cursorX = _rightLimit - 1;
      count -= 1;
      if (count == 0) return;
    }

    if (wrapMode == _CursorLeftWrapMode.none) {
      setCursorX(_cursorX - count);
      return;
    }

    final top = _marginTop;
    final bottom = _marginBottom;
    final right = _marginRight;
    final left = switch (_cursorX < _marginLeft) {
      true => 0,
      false => _marginLeft,
    };

    if (_cursorX == left &&
        wrapMode == _CursorLeftWrapMode.reverse &&
        _cursorY <= top) {
      _cursorX = left;
      _cursorY = top;
      return;
    }

    while (count > 0) {
      final amount = min(_cursorX - left, count);
      _cursorX -= amount;
      count -= amount;
      if (count == 0) return;

      if (_cursorY == top) {
        if (wrapMode != _CursorLeftWrapMode.reverseExtended) return;

        _cursorX = right;
        _cursorY = bottom;
        count -= 1;
        continue;
      }

      if (_cursorY == 0) return;

      if (wrapMode == _CursorLeftWrapMode.reverse) {
        if (!currentLine.isWrapped) return;
      }

      _cursorX = right;
      _cursorY -= 1;
      count -= 1;
    }
  }

  bool get _isPendingWrap {
    return _cursorX == _rightLimit;
  }

  void _cancelPendingWrap() {
    if (!_isPendingWrap) return;
    _cursorX = _rightLimit - 1;
  }

  _CursorLeftWrapMode get _cursorLeftWrapMode {
    if (!terminal.autoWrapMode) return _CursorLeftWrapMode.none;
    if (terminal.reverseWrapExtendedMode) {
      return _CursorLeftWrapMode.reverseExtended;
    }
    if (terminal.reverseWrapMode) return _CursorLeftWrapMode.reverse;
    return _CursorLeftWrapMode.none;
  }

  void moveCursorY(int offset) {
    final constrainedToMargins = terminal.originMode || isInVerticalMargin;
    final minimumY = switch (constrainedToMargins) {
      true => _marginTop,
      false => 0,
    };
    final maximumY = switch (constrainedToMargins) {
      true => _marginBottom,
      false => viewHeight - 1,
    };
    _cursorY = (_cursorY + offset).clamp(minimumY, maximumY);
  }

  void setCursor(int cursorX, int cursorY) {
    var minimumCursorX = 0;
    var maximumCursorX = viewWidth - 1;
    var maxCursorY = viewHeight - 1;

    if (terminal.originMode) {
      cursorX += _marginLeft;
      cursorY += _marginTop;
      minimumCursorX = _marginLeft;
      maximumCursorX = _marginRight;
      maxCursorY = _marginBottom;
    }

    // Compared rather than clamped: every cursor move in full-screen output
    // comes through here, and int.clamp is a call that checks its bounds.
    _cursorX = cursorX < minimumCursorX
        ? minimumCursorX
        : cursorX > maximumCursorX
            ? maximumCursorX
            : cursorX;
    _cursorY = cursorY < 0
        ? 0
        : cursorY > maxCursorY
            ? maxCursorY
            : cursorY;
  }

  void moveCursor(int offsetX, int offsetY) {
    moveCursorX(offsetX);
    moveCursorY(offsetY);
  }

  /// Save cursor position, charmap and text attributes.
  void saveCursor({required bool originMode}) {
    _savedCursorX = _cursorX;
    _savedCursorY = _cursorY;
    _savedPendingWrap = _cursorX >= _rightLimit;
    _savedOriginMode = originMode;
    _savedCursorStyle.foreground = terminal.cursor.foreground;
    _savedCursorStyle.background = terminal.cursor.background;
    _savedCursorStyle.underlineColor = terminal.cursor.underlineColor;
    _savedCursorStyle.attrs = terminal.cursor.attrs;
    _savedCursorStyle.hyperlinkId = terminal.cursor.hyperlinkId;
    _savedCharset.copyFrom(charset);
  }

  void clearSavedCursorHyperlink() {
    _savedCursorStyle.hyperlinkId = 0;
  }

  void resetSavedCharset() {
    _savedCharset.reset();
  }

  /// Restore cursor position, charmap and text attributes.
  bool restoreCursor() {
    _cursorX = _savedCursorX;
    _cursorY = _savedCursorY;
    terminal.cursor.foreground = _savedCursorStyle.foreground;
    terminal.cursor.background = _savedCursorStyle.background;
    terminal.cursor.underlineColor = _savedCursorStyle.underlineColor;
    terminal.cursor.attrs = _savedCursorStyle.attrs;
    terminal.cursor.hyperlinkId = _savedCursorStyle.hyperlinkId;
    charset.copyFrom(_savedCharset);
    return _savedOriginMode;
  }

  /// Sets the vertical scrolling margin to [top] and [bottom].
  /// Both values must be between 0 and [viewHeight] - 1.
  void setVerticalMargins(int top, int bottom) {
    _marginTop = top.clamp(0, viewHeight - 1);
    _marginBottom = bottom.clamp(0, viewHeight - 1);

    _marginTop = min(_marginTop, _marginBottom);
    _marginBottom = max(_marginTop, _marginBottom);
  }

  /// Sets the horizontal scrolling margin to [left] and [right].
  /// Both values must be between 0 and [viewWidth] - 1.
  void setHorizontalMargins(int left, int right) {
    final effectiveLeft = left.clamp(0, viewWidth - 1);
    final effectiveRight = right.clamp(0, viewWidth - 1);
    if (effectiveLeft >= effectiveRight) return;

    _marginLeft = effectiveLeft;
    _marginRight = effectiveRight;
  }

  bool get isInVerticalMargin {
    return _cursorY >= _marginTop && _cursorY <= _marginBottom;
  }

  bool get isInHorizontalMargin {
    return _cursorX >= _marginLeft && _cursorX <= _marginRight;
  }

  bool get isInHorizontalMarginOrPendingWrap {
    return _cursorX >= _marginLeft && _cursorX <= _marginRight + 1;
  }

  void resetVerticalMargins() {
    setVerticalMargins(0, viewHeight - 1);
  }

  void resetHorizontalMargins() {
    _marginLeft = 0;
    _marginRight = viewWidth - 1;
  }

  void carriageReturn() {
    // What setCursorX comes to for either target, the left margin being at or
    // left of the right one.
    _cursorX = terminal.originMode || _cursorX >= _marginLeft ? _marginLeft : 0;
  }

  int _minimumCursorX(int targetX) {
    if (terminal.originMode) return _marginLeft;
    if (_cursorX < _marginLeft && targetX < _marginLeft) return 0;
    return _marginLeft;
  }

  int _maximumCursorX(int targetX) {
    if (terminal.originMode) return _marginRight;
    if (_cursorX > _marginRight && targetX > _marginRight) {
      return viewWidth - 1;
    }
    return _marginRight;
  }

  int get _rightLimit {
    return switch (_cursorX <= _marginRight + 1) {
      true => _marginRight + 1,
      false => viewWidth,
    };
  }

  void deleteChars(int count) {
    _cancelPendingWrap();
    final start = _cursorX.clamp(0, viewWidth - 1);
    count = min(count, _rightLimit - start);
    currentLine.removeCells(start, count, _blankCellStyle, _rightLimit);
  }

  void insertColumns(int count) {
    _cancelPendingWrap();
    if (!isInVerticalMargin || !isInHorizontalMargin) {
      return;
    }

    count = min(count, _marginRight - _cursorX + 1);
    for (var row = absoluteMarginTop; row <= absoluteMarginBottom; row++) {
      lines[row]
          .insertCells(_cursorX, count, _blankCellStyle, _marginRight + 1);
    }
  }

  void deleteColumns(int count) {
    _cancelPendingWrap();
    if (!isInVerticalMargin || !isInHorizontalMargin) {
      return;
    }

    count = min(count, _marginRight - _cursorX + 1);
    for (var row = absoluteMarginTop; row <= absoluteMarginBottom; row++) {
      lines[row]
          .removeCells(_cursorX, count, _blankCellStyle, _marginRight + 1);
    }
  }

  bool get _usesFullHorizontalMargins {
    return _marginLeft == 0 && _marginRight == viewWidth - 1;
  }

  /// Remove all lines above the top of the viewport.
  void clearScrollback() {
    if (height <= viewHeight) {
      return;
    }

    lines.trimStart(scrollBack);
    _forceScrollToBottomGeneration++;
  }

  /// Moves the current viewport into scrollback and replaces it with blanks.
  void scrollClear() {
    final lineCount = _visibleContentLineCount();
    for (var i = 0; i < lineCount; i++) {
      lines.push(_newEmptyLine());
    }
    _forceScrollToBottomGeneration++;
  }

  int _visibleContentLineCount() {
    for (var row = viewHeight - 1; row >= 0; row--) {
      final line = lines[row + scrollBack];
      if (_lineHasContent(line)) return row + 1;
    }
    return 0;
  }

  bool _lineHasContent(BufferLine line) {
    for (var column = 0; column < viewWidth; column++) {
      if (line.getContent(column) != 0) return true;
      if (line.getForeground(column) != CellColor.normal) return true;
      if (line.getBackground(column) != CellColor.normal) return true;
      if (line.getAttributes(column) & ~CellAttr.semanticMask != 0) return true;
      if (line.getUnderlineColor(column) != CellColor.normal) return true;
    }
    return false;
  }

  /// Clears scrollback and viewport content before the active prompt/input.
  ///
  /// This follows terminal clear actions that keep the current prompt visible
  /// while dropping previous output.
  void clear() {
    var promptStart = absoluteCursorY;
    while (promptStart > scrollBack && lines[promptStart].isWrapped) {
      promptStart--;
    }

    final promptEnd = absoluteCursorY;
    final promptLines = <BufferLine>[];
    for (var index = promptStart; index <= promptEnd; index++) {
      final line = BufferLine(viewWidth)
        ..copyFrom(lines[index], 0, 0, viewWidth)
        ..isWrapped = lines[index].isWrapped;
      promptLines.add(line);
    }

    lines.clear();

    final promptTop = max(0, viewHeight - promptLines.length);
    for (var row = 0; row < viewHeight; row++) {
      final promptIndex = row - promptTop;
      if (promptIndex >= 0 && promptIndex < promptLines.length) {
        lines.push(promptLines[promptIndex]);
        continue;
      }
      lines.push(_newEmptyLine());
    }

    _cursorY = min(promptTop + promptLines.length - 1, viewHeight - 1);
    _forceScrollToBottomGeneration++;
  }

  void _clearAll() {
    lines.clear();
    for (var i = 0; i < viewHeight; i++) {
      lines.push(_newEmptyLine());
    }
    _forceScrollToBottomGeneration++;
  }

  void reset() {
    _clearAll();
    _cursorX = 0;
    _cursorY = 0;
    _savedCursorX = 0;
    _savedCursorY = 0;
    _savedPendingWrap = false;
    _savedOriginMode = false;
    _savedCursorStyle.reset();
    _savedCursorStyle.hyperlinkId = 0;
    _savedCharset.reset();
    resetVerticalMargins();
    resetHorizontalMargins();
  }

  void screenAlignmentTest(CursorStyle style) {
    final viewportStart = scrollBack;
    final viewportEnd = viewportStart + viewHeight;
    resetVerticalMargins();
    resetHorizontalMargins();
    for (var row = viewportStart; row < viewportEnd; row++) {
      final line = lines[row];
      line.isWrapped = false;
      for (var column = 0; column < viewWidth; column++) {
        line.setCell(column, 0x45, 1, style);
      }
    }
    _cursorX = 0;
    _cursorY = 0;
  }

  void resetViewport() {
    final viewportStart = scrollBack;
    final viewportEnd = viewportStart + viewHeight;
    for (var row = viewportStart; row < viewportEnd; row++) {
      final line = lines[row];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, CursorStyle.empty);
    }
    _cursorX = 0;
    _cursorY = 0;
    resetVerticalMargins();
    resetHorizontalMargins();
  }

  void insertBlankChars(int count) {
    _cancelPendingWrap();
    count = min(count, _rightLimit - _cursorX);
    currentLine.insertCells(_cursorX, count, _blankCellStyle, _rightLimit);
  }

  CursorStyle get _blankCellStyle {
    final style = terminal.cursor;
    return CursorStyle(
      foreground: style.foreground,
      background: style.background,
      underlineColor: style.underlineColor,
      attrs: style.attrs,
      semanticAttrs: style.semanticAttrs,
    );
  }

  void insertLines(int count) {
    _cancelPendingWrap();
    if (!isInVerticalMargin || !isInHorizontalMargin) {
      return;
    }

    setCursorX(_marginLeft);

    // Number of lines from the cursor to the bottom of the scrollable region
    // including the cursor itself.
    final linesBelow = absoluteMarginBottom - absoluteCursorY + 1;

    // Number of empty lines to insert.
    final linesToInsert = min(count, linesBelow);

    // Number of lines to move up.
    final linesToMove = linesBelow - linesToInsert;

    if (!_usesFullHorizontalMargins) {
      final width = _marginRight - _marginLeft + 1;
      for (var i = 0; i < linesToMove; i++) {
        final index = absoluteMarginBottom - i;
        lines[index].copyFrom(
          lines[index - linesToInsert],
          _marginLeft,
          _marginLeft,
          width,
        );
      }

      for (var i = 0; i < linesToInsert; i++) {
        lines[absoluteCursorY + i].eraseRange(
          _marginLeft,
          _marginRight + 1,
          terminal.cursor,
        );
      }
      return;
    }

    for (var i = 0; i < linesToMove; i++) {
      final index = absoluteMarginBottom - i;
      lines[index] = lines.swap(index - linesToInsert, _newScrolledLine());
    }

    for (var i = linesToMove; i < linesToInsert; i++) {
      lines[absoluteCursorY + i] = _newScrolledLine();
    }
  }

  /// Remove [count] lines starting at the current cursor position. Lines below
  /// the removed lines are shifted up. This only affects the scrollable region.
  /// Lines outside the scrollable region are not affected.
  void deleteLines(int count) {
    _cancelPendingWrap();
    if (!isInVerticalMargin || !isInHorizontalMargin) {
      return;
    }

    setCursorX(_marginLeft);

    count = min(count, absoluteMarginBottom - absoluteCursorY + 1);

    final linesToMove = absoluteMarginBottom - absoluteCursorY + 1 - count;

    if (!_usesFullHorizontalMargins) {
      final width = _marginRight - _marginLeft + 1;
      for (var i = 0; i < linesToMove; i++) {
        final index = absoluteCursorY + i;
        lines[index].copyFrom(
          lines[index + count],
          _marginLeft,
          _marginLeft,
          width,
        );
      }

      for (var i = 0; i < count; i++) {
        lines[absoluteMarginBottom - i].eraseRange(
          _marginLeft,
          _marginRight + 1,
          terminal.cursor,
        );
      }
      return;
    }

    for (var i = 0; i < linesToMove; i++) {
      final index = absoluteCursorY + i;
      lines.move(index + count, index);
    }

    for (var i = 0; i < count; i++) {
      lines[absoluteMarginBottom - i] = _newScrolledLine();
    }
  }

  void resize(int oldWidth, int oldHeight, int newWidth, int newHeight) {
    if (newHeight > lines.maxLength) {
      lines.maxLength = newHeight;
    }

    // 1. Adjust the height.
    if (newHeight > oldHeight) {
      // Grow larger
      for (var i = 0; i < newHeight - oldHeight; i++) {
        if (newHeight > lines.length) {
          lines.push(_newEmptyLine(newWidth));
        } else {
          _cursorY++;
          _savedCursorY++;
        }
      }
    } else {
      // Shrink smaller
      for (var i = 0; i < oldHeight - newHeight; i++) {
        if (_cursorY > newHeight - 1) {
          _cursorY--;
          _savedCursorY--;
        } else {
          lines.pop();
        }
      }
    }

    // Ensure cursor row is within the screen. The column is clamped after
    // width handling so reflow can preserve its logical offset.
    _cursorY = _cursorY.clamp(0, newHeight - 1);
    _savedCursorY = _savedCursorY.clamp(0, newHeight - 1);

    // 2. Adjust the width.
    if (newWidth != oldWidth) {
      if (terminal.reflowEnabled && !isAltBuffer) {
        final cursorScrollBack = max(lines.length - newHeight, 0);
        final cursorLine = _cursorY + cursorScrollBack;
        final cursorPendingWrap = _cursorX >= _rightLimit;
        final cursorAnchorX = switch (cursorPendingWrap) {
          true => max(0, _cursorX - 1),
          false => _cursorX,
        };
        final cursorAnchor = lines[cursorLine].createAnchor(cursorAnchorX);
        final savedCursorLine = _savedCursorY + cursorScrollBack;
        final savedCursorAnchorX = switch (_savedPendingWrap) {
          true => max(0, _savedCursorX - 1),
          false => _savedCursorX,
        };
        final savedCursorAnchor =
            lines[savedCursorLine].createAnchor(savedCursorAnchorX);
        final reflowResult = reflow(lines, oldWidth, newWidth);

        while (reflowResult.length < newHeight) {
          reflowResult.add(_newEmptyLine(newWidth));
        }

        lines.replaceWith(reflowResult);
        // Reflow can add rows above the cursor. Drop blank rows below it
        // instead of pushing the cursor's row up into scrollback.
        while (cursorAnchor.attached &&
            lines.length > newHeight &&
            cursorAnchor.y < lines.length - newHeight &&
            lines[lines.length - 1].getTrimmedLength() == 0) {
          lines.pop();
        }
        if (cursorAnchor.attached) {
          final newScrollBack = max(lines.length - newHeight, 0);
          _cursorX = _reflowedCursorX(
            cursorAnchor,
            pendingWrap: cursorPendingWrap,
            newWidth: newWidth,
          );
          _cursorY = (cursorAnchor.y - newScrollBack).clamp(0, newHeight - 1);
        }
        if (savedCursorAnchor.attached) {
          final newScrollBack = max(lines.length - newHeight, 0);
          _savedCursorX = _reflowedCursorX(
            savedCursorAnchor,
            pendingWrap: _savedPendingWrap,
            newWidth: newWidth,
          );
          _savedCursorY =
              (savedCursorAnchor.y - newScrollBack).clamp(0, newHeight - 1);
          _savedPendingWrap = _savedCursorX == newWidth;
        } else {
          _savedCursorX = _savedCursorX.clamp(0, newWidth - 1);
          _savedPendingWrap = false;
        }
        cursorAnchor.dispose();
        savedCursorAnchor.dispose();
      } else {
        lines.forEach((item) {
          // BufferLine.resize intentionally preserves cell data beyond the
          // new length so it can reappear if the line is grown back later
          // (see the "preserves hidden cells" resize tests) - it does not
          // enforce the width-2/placeholder pairing invariant. If this line
          // was shrunk smaller than newWidth in the past and is now being
          // grown, the newly exposed last cell may be a stale wide-char
          // lead with no room left for its placeholder, so clear it (same
          // guard applied by reflow() for the reflow-enabled path).
          item.resize(newWidth);
          if (newWidth > 0 && item.getWidth(newWidth - 1) == 2) {
            item.resetCell(newWidth - 1);
          }
        });
        _cursorX = _cursorX.clamp(0, newWidth - 1);
        _savedCursorX = _savedCursorX.clamp(0, newWidth - 1);
        _savedPendingWrap = false;
      }
    }

    _cursorX = _cursorX.clamp(0, newWidth);
    _marginLeft = 0;
    _marginRight = newWidth - 1;
  }

  int _reflowedCursorX(
    CellAnchor anchor, {
    required bool pendingWrap,
    required int newWidth,
  }) {
    if (pendingWrap && anchor.x == newWidth - 1) return newWidth;
    // Right after text that now exactly fills its row: stay in the
    // pending-wrap position so the next character does not overwrite it.
    if (anchor.x >= newWidth && anchor.line!.getTrimmedLength() == newWidth) {
      return newWidth;
    }
    final offset = switch (pendingWrap) {
      true => 1,
      false => 0,
    };
    return (anchor.x + offset).clamp(0, newWidth - 1);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchor(int x, int y) {
    return lines[y].createAnchor(x);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchorFromOffset(CellOffset offset) {
    return lines[offset.y].createAnchor(offset.x);
  }

  CellAnchor createAnchorFromCursor() {
    return createAnchor(cursorX, absoluteCursorY);
  }

  /// Whether [anchor] belongs to a line in this buffer.
  bool ownsAnchor(CellAnchor anchor) {
    final line = anchor.line;
    if (line == null || !line.attached) {
      return false;
    }

    final index = line.index;
    if (index < 0 || index >= lines.length) {
      return false;
    }

    return identical(lines[index], line);
  }

  /// Create a new empty [BufferLine] with the current [viewWidth] if [width]
  /// is not specified.
  BufferLine _newEmptyLine([int? width]) {
    final line = BufferLine(width ?? viewWidth);
    if (_spareStorage case final storage?) {
      _spareStorage = null;
      line.adoptStorage(storage);
    }
    return line;
  }

  /// A new line for one that scrolling, IL or DL opens: blank in the current
  /// background, as an erase leaves it (bce).
  BufferLine _newScrolledLine() {
    final line = _newEmptyLine();
    final style = terminal.cursor;
    if (style.background != 0) line.eraseRange(0, viewWidth, style);
    return line;
  }

  static final defaultWordSeparators = <int>{
    0,
    r' '.codeUnitAt(0),
    '\t'.codeUnitAt(0),
    r"'".codeUnitAt(0),
    r'"'.codeUnitAt(0),
    '│'.codeUnitAt(0),
    r'`'.codeUnitAt(0),
    r'|'.codeUnitAt(0),
    r':'.codeUnitAt(0),
    r';'.codeUnitAt(0),
    r','.codeUnitAt(0),
    r'('.codeUnitAt(0),
    r')'.codeUnitAt(0),
    r'['.codeUnitAt(0),
    r']'.codeUnitAt(0),
    r'{'.codeUnitAt(0),
    r'}'.codeUnitAt(0),
    r'<'.codeUnitAt(0),
    r'>'.codeUnitAt(0),
    r'$'.codeUnitAt(0),
  };

  BufferRangeLine? getWordBoundary(CellOffset position) {
    var separators = wordSeparators ?? defaultWordSeparators;
    if (position.y >= lines.length) {
      return null;
    }

    var startLine = position.y;
    var start = position.x;
    var endLine = position.y;
    var end = position.x;

    do {
      if (start == 0) {
        if (!_lineContinuesFromPrevious(startLine)) break;
        startLine--;
        start = viewWidth;
      }
      final line = lines[startLine];
      var previous = start - 1;
      if (previous > 0 &&
          line.getWidth(previous) == 0 &&
          line.getWidth(previous - 1) == 2) {
        previous--;
      }
      final char = line.getCodePoint(previous);
      if (separators.contains(char)) {
        break;
      }
      start = previous;
    } while (true);

    do {
      if (end >= viewWidth) {
        if (!_lineContinuesToNext(endLine)) break;
        endLine++;
        end = 0;
      }
      final line = lines[endLine];
      final width = line.getWidth(end);
      if (width == 0 && end > 0 && line.getWidth(end - 1) == 2) {
        end++;
        continue;
      }
      final char = line.getCodePoint(end);
      if (separators.contains(char)) {
        break;
      }
      end += switch (width) {
        2 => 2,
        _ => 1,
      };
    } while (true);

    if (start == end && startLine == endLine) {
      return null;
    }

    return BufferRangeLine(
      CellOffset(start, startLine),
      CellOffset(end, endLine),
    );
  }

  BufferRangeLine? getLineBoundary(CellOffset position) {
    if (position.y < 0 || position.y >= lines.length) {
      return null;
    }

    var startLine = position.y;
    while (_lineContinuesFromPrevious(startLine)) {
      startLine--;
    }

    var endLine = position.y;
    while (_lineContinuesToNext(endLine)) {
      endLine++;
    }

    while (startLine < endLine && _lineHasOnlyWhitespace(startLine)) {
      startLine++;
    }

    while (endLine > startLine && _lineHasOnlyWhitespace(endLine)) {
      endLine--;
    }

    final startColumn = _firstNonWhitespaceColumn(startLine);
    final endColumn = _lastNonWhitespaceColumnEnd(endLine);
    if (startColumn == viewWidth && endColumn == 0) {
      return BufferRangeLine(
        CellOffset(0, startLine),
        CellOffset(viewWidth, endLine),
      );
    }

    return BufferRangeLine(
      CellOffset(startColumn, startLine),
      CellOffset(endColumn, endLine),
    );
  }

  bool _lineHasOnlyWhitespace(int lineIndex) {
    return _firstNonWhitespaceColumn(lineIndex) == viewWidth;
  }

  int _firstNonWhitespaceColumn(int lineIndex) {
    final line = lines[lineIndex];
    for (var column = 0; column < viewWidth; column++) {
      if (!_isLineBoundaryWhitespace(line.getCodePoint(column))) {
        return column;
      }
    }
    return viewWidth;
  }

  int _lastNonWhitespaceColumnEnd(int lineIndex) {
    final line = lines[lineIndex];
    for (var column = viewWidth - 1; column >= 0; column--) {
      if (_isLineBoundaryWhitespace(line.getCodePoint(column))) {
        continue;
      }
      return column +
          switch (line.getWidth(column)) {
            2 => 2,
            _ => 1,
          };
    }
    return 0;
  }

  bool _isLineBoundaryWhitespace(int codePoint) {
    return switch (codePoint) {
      0 || 0x09 || 0x20 => true,
      _ => false,
    };
  }

  bool _lineContinuesFromPrevious(int lineIndex) {
    return lineIndex > 0 && lines[lineIndex].isWrapped;
  }

  bool _lineContinuesToNext(int lineIndex) {
    final nextLine = lineIndex + 1;
    return nextLine < lines.length && lines[nextLine].isWrapped;
  }

  /// Get the plain text content of the buffer including the scrollback.
  /// Accepts an optional [range] to get a specific part of the buffer.
  String getText([BufferRange? range, bool trimWhitespace = false]) {
    range ??= BufferRangeLine(
      CellOffset(0, 0),
      CellOffset(viewWidth, height - 1),
    );

    range = range.normalized;

    final chunks = <String>[];

    for (var segment in range.toSegments()) {
      if (segment.line < 0 || segment.line >= height) {
        continue;
      }
      final line = lines[segment.line];
      final joinWrappedLine = range is! BufferRangeBlock && line.isWrapped;
      if (!(segment.line == range.begin.y ||
          segment.line == 0 ||
          joinWrappedLine)) {
        if (trimWhitespace) {
          _trimTrailingSelectionWhitespace(chunks);
        }
        chunks.add('\n');
      }
      chunks.add(line.getText(segment.start, segment.end));
    }

    if (trimWhitespace) {
      _trimTrailingSelectionWhitespace(chunks);
    }

    return chunks.join();
  }

  void _trimTrailingSelectionWhitespace(List<String> chunks) {
    while (chunks.isNotEmpty) {
      final chunk = chunks.last;
      final trimmed = _trimRightSelectionWhitespace(chunk);
      if (trimmed.length == chunk.length) return;
      if (trimmed.isNotEmpty) {
        chunks[chunks.length - 1] = trimmed;
        return;
      }
      chunks.removeLast();
    }
  }

  String _trimRightSelectionWhitespace(String text) {
    var end = text.length;
    while (end > 0) {
      final codeUnit = text.codeUnitAt(end - 1);
      if (codeUnit != 0x20 && codeUnit != 0x09) break;
      end--;
    }
    return switch (end == text.length) {
      true => text,
      false => text.substring(0, end),
    };
  }

  /// Returns a debug representation of the buffer.
  @override
  String toString() {
    final builder = StringBuffer();
    final lineNumberLength = lines.length.toString().length;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      builder.write('${i.toString().padLeft(lineNumberLength)}: |${lines[i]}|');

      if (line.isWrapped) {
        builder.write(' (⏎)');
      }

      builder.write('\n');
    }

    return builder.toString();
  }
}

enum _CursorLeftWrapMode {
  none,
  reverse,
  reverseExtended,
}
