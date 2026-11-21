import 'dart:collection';
import 'package:xterm3/src/utils/single_cell_text.dart';

class ByteConsumer {
  final _queue = ListQueue<_StringBlock>();

  /// The string of the head block of [_queue], or '' when it is empty.
  ///
  /// Every read of the input goes through the head block, and reaching it
  /// through `_queue.first` costs an emptiness check, a cast and a bounds
  /// check: about seven of those per text run and four per code point taken
  /// one at a time, plus the same again in [_advancePastConsumedBlocks]. Read
  /// from this field instead, the parser took 23-29% less time on SGR-dense,
  /// cursor-addressed, CJK and other Unicode output and 10-16% less on plain
  /// text; Terminal.write 18-20% less on the first two (AOT, M1 Pro, 64 MiB
  /// payloads at 100x37).
  ///
  /// It is only correct while it is the head, so everything that changes the
  /// head of [_queue] - [add] to an empty queue, the `addFirst` in [rollback],
  /// the `removeFirst` in [_advancePastConsumedBlocks], [unrefConsumedBlocks]
  /// and [reset] - sets it again right there. Offsets are not cached:
  /// [_currentOffset] already lives in a field.
  var _head = '';

  final _consumed = ListQueue<_StringBlock>();

  var _currentOffset = 0;

  var _remainingCodeUnits = 0;

  var _totalConsumed = 0;

  var _rollbackAvailable = 0;

  void add(String data) {
    if (data.isEmpty) return;
    if (_queue.isEmpty) _head = data;
    _queue.addLast(_StringBlock(data));
    _remainingCodeUnits += data.length;
  }

  int peek() {
    final result = consume();
    rollback();
    return result;
  }

  int consume() {
    _advancePastConsumedBlocks();
    final data = _head;
    final first = data.codeUnitAt(_currentOffset);

    // A unit that does not start a surrogate pair is one code unit long and
    // is its own code point. That is what the two calls below work out for it
    // anyway, each re-running this same test. Everything outside astral text
    // takes this branch: CSI parameters, C0 controls, Latin, Cyrillic, and the
    // per-code-point path for text the run scan could not batch.
    if (!_isHighSurrogate(first)) {
      _currentOffset++;
      _remainingCodeUnits--;
      _totalConsumed++;
      _rollbackAvailable++;
      return first;
    }

    final codePoint = _decodeCodePoint(data, _currentOffset, first);
    final codeUnitLength = _codePointCodeUnitLength(
      data,
      _currentOffset,
      first,
    );
    _currentOffset += codeUnitLength;
    _remainingCodeUnits -= codeUnitLength;
    _totalConsumed++;
    _rollbackAvailable++;
    return codePoint;
  }

  /// Rolls back the last [n] calls to [consume].
  void rollback([int n = 1]) {
    if (n < 0 || n > _rollbackAvailable) {
      throw RangeError.range(n, 0, _rollbackAvailable, 'n');
    }

    var remaining = n;
    while (remaining > 0) {
      if (_currentOffset == 0) {
        final block = _consumed.removeLast();
        _queue.addFirst(block);
        _head = block.data;
        _currentOffset = block.data.length;
      }

      assert(_headIsCurrent);
      final previousOffset = _previousRuneOffset(_head, _currentOffset);
      _remainingCodeUnits += _currentOffset - previousOffset;
      _currentOffset = previousOffset;
      remaining--;
    }
    _totalConsumed -= n;
    _rollbackAvailable -= n;
  }

  /// Rolls back to the state when this consumer had [length] runes.
  void rollbackTo(int length) {
    rollback(length - this.length);
  }

  int get length {
    var count = 0;
    var isFirst = true;
    for (final block in _queue) {
      final start = switch (isFirst) {
        true => _currentOffset,
        false => 0,
      };
      count += _countRunes(block.data, start);
      isFirst = false;
    }
    return count;
  }

  int get totalConsumed => _totalConsumed;

  bool get isEmpty => _remainingCodeUnits == 0;

  bool get isNotEmpty => _remainingCodeUnits != 0;

  String get currentBlock {
    _advancePastConsumedBlocks();
    return _head;
  }

  int get printableAsciiRunLength {
    _advancePastConsumedBlocks();
    final data = _head;
    var offset = _currentOffset;
    while (offset < data.length) {
      final codeUnit = data.codeUnitAt(offset);
      if (codeUnit < 0x20 || codeUnit > 0x7e) break;
      offset++;
    }
    return offset - _currentOffset;
  }

  /// The head block, without first stepping past it if it has been consumed
  /// to its end, as [currentBlock] does. Right after [consume] it is the
  /// block the unit it returned came from.
  String get headBlock {
    assert(_headIsCurrent);
    return _head;
  }

  /// The offset into [headBlock] of the next code unit; right after [consume]
  /// has returned a single code unit, one past where that unit sits.
  int get headOffset => _currentOffset;

  /// Consumes the code units of [headBlock] up to [offset], for a caller that
  /// has scanned them itself; each must be a code point of its own.
  ///
  /// It neither steps past a consumed head block nor range-checks the count:
  /// the parser commits every token it scans in the head block through this,
  /// and those two would cost it on each.
  void consumeHeadTo(int offset) {
    assert(_headIsCurrent);
    assert(offset >= _currentOffset && offset <= _head.length);
    final count = offset - _currentOffset;
    _currentOffset = offset;
    _remainingCodeUnits -= count;
    _totalConsumed += count;
    _rollbackAvailable += count;
  }

  /// Consumes the run of [isSingleCellPrintable] and [isWideRunUnit] code
  /// units and [isWideRunEmoji] surrogate pairs starting at [headOffset], and
  /// returns where in [headBlock] it ends. Used to carry on a run that a wide
  /// character, just consumed, has started, or a single-cell run, just
  /// consumed, that a wide character goes on with; like [consume], it counts
  /// a pair as one.
  int consumeTextRunInHead() {
    assert(_headIsCurrent);
    final data = _head;
    final start = _currentOffset;
    var offset = start;
    var codePoints = 0;
    final classes = runClasses;
    while (offset < data.length) {
      final codeUnit = data.codeUnitAt(offset);
      if (classes[codeUnit] != runClassOther) {
        offset++;
      } else if (_isHighSurrogate(codeUnit) &&
          offset + 1 < data.length &&
          _isLowSurrogate(data.codeUnitAt(offset + 1)) &&
          isWideRunEmoji(
              _combineSurrogates(codeUnit, data.codeUnitAt(offset + 1)))) {
        offset += 2;
      } else {
        break;
      }
      codePoints++;
    }
    _currentOffset = offset;
    _remainingCodeUnits -= offset - start;
    _totalConsumed += codePoints;
    _rollbackAvailable += codePoints;
    return offset;
  }

  /// Returns the most recently consumed [length] characters, as far as they
  /// are still retained (i.e. have not been discarded by a call to
  /// [unrefConsumedBlocks] since they were consumed). If part of the
  /// requested range was already discarded, the returned string is
  /// truncated to whatever is still available.
  ///
  /// This is intended for diagnostics only (unknown-sequence callbacks) and
  /// is never called on the hot path when no diagnostic callback is
  /// registered.
  String recentConsumed(int length) {
    if (length <= 0) return '';

    final parts = <String>[];
    var remaining = length;

    if (_queue.isNotEmpty && _currentOffset > 0) {
      final data = _queue.first.data;
      final take = remaining < _currentOffset ? remaining : _currentOffset;
      parts.add(data.substring(_currentOffset - take, _currentOffset));
      remaining -= take;
    }

    if (remaining > 0) {
      for (final block in _consumed.toList(growable: false).reversed) {
        if (remaining <= 0) break;
        final data = block.data;
        final take = remaining < data.length ? remaining : data.length;
        parts.add(data.substring(data.length - take));
        remaining -= take;
      }
    }

    return parts.reversed.join();
  }

  /// Unreferences blocks consumed before the current parsing transaction.
  void unrefConsumedBlocks() {
    _consumed.clear();
    while (_queue.isNotEmpty && _currentOffset >= _queue.first.data.length) {
      _currentOffset -= _queue.removeFirst().data.length;
    }
    if (_queue.isNotEmpty && _currentOffset > 0) {
      final remainingData = _queue.removeFirst().data.substring(_currentOffset);
      _queue.addFirst(_StringBlock(remainingData));
      _currentOffset = 0;
    }
    _head = _queue.isEmpty ? '' : _queue.first.data;
    _rollbackAvailable = 0;
  }

  /// Resets the consumer to its initial state.
  void reset() {
    _queue.clear();
    _consumed.clear();
    _currentOffset = 0;
    _totalConsumed = 0;
    _rollbackAvailable = 0;
    _remainingCodeUnits = 0;
    _head = '';
  }

  /// Whether [_head] is the head block's string. Asserted where the cache is
  /// read, so a test that leaves it stale fails there instead of reading
  /// the wrong text.
  bool get _headIsCurrent =>
      identical(_head, _queue.isEmpty ? '' : _queue.first.data);

  void _advancePastConsumedBlocks() {
    assert(_headIsCurrent);
    // On an empty queue `_head` is '' and `removeFirst` throws StateError,
    // as `_queue.first` did before the head was cached.
    while (_currentOffset >= _head.length) {
      final block = _queue.removeFirst();
      _consumed.addLast(block);
      _currentOffset -= block.data.length;
      _head = _queue.isEmpty ? '' : _queue.first.data;
    }
  }
}

class _StringBlock {
  const _StringBlock(this.data);

  final String data;
}

int _countRunes(String data, int start) {
  var count = 0;
  var offset = start;
  while (offset < data.length) {
    final first = data.codeUnitAt(offset);
    offset += _codePointCodeUnitLength(data, offset, first);
    count++;
  }
  return count;
}

int _decodeCodePoint(String data, int offset, int first) {
  if (!_isHighSurrogate(first) || offset + 1 >= data.length) {
    return first;
  }

  final second = data.codeUnitAt(offset + 1);
  if (!_isLowSurrogate(second)) return first;
  return 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
}

int _combineSurrogates(int high, int low) =>
    0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);

int _codePointCodeUnitLength(String data, int offset, int first) {
  if (!_isHighSurrogate(first) || offset + 1 >= data.length) return 1;
  return switch (_isLowSurrogate(data.codeUnitAt(offset + 1))) {
    true => 2,
    false => 1,
  };
}

int _previousRuneOffset(String data, int offset) {
  final previous = offset - 1;
  if (previous <= 0 || !_isLowSurrogate(data.codeUnitAt(previous))) {
    return previous;
  }
  return switch (_isHighSurrogate(data.codeUnitAt(previous - 1))) {
    true => previous - 1,
    false => previous,
  };
}

bool _isHighSurrogate(int codeUnit) {
  return codeUnit >= 0xd800 && codeUnit <= 0xdbff;
}

bool _isLowSurrogate(int codeUnit) {
  return codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
}
