import 'dart:convert';
import 'dart:typed_data';

const _sdk = Utf8Decoder(allowMalformed: true);

/// A chunked UTF-8 decoder that gives exactly what a chunked
/// `Utf8Decoder(allowMalformed: true)` gives, faster on the output a terminal
/// gets.
///
/// The SDK decoder pays for any non-ASCII byte in a chunk with the whole
/// chunk: it builds one two-byte string out of all of it, about 1.7 ns a code
/// unit. Mostly-ASCII output - logs, prose, source code with the odd accented
/// letter, dash or quote - is made of exactly such chunks. Here each ASCII run
/// becomes a one-byte string, which is a copy, the few non-ASCII stretches
/// between them are decoded on their own, and the pieces are joined.
///
/// A dense chunk - CJK, emoji, accented alphabets, box drawing - would make
/// many tiny pieces, so it goes through a loop that decodes into UTF-16 code
/// units instead. Which one a chunk takes is judged from its first 64 bytes,
/// and a chunk that turns dense later switches over.
///
/// Malformed input goes to the SDK decoder, from the first bad byte to the end
/// of the stretch or chunk, so where U+FFFD lands is the SDK's own decision. A
/// sequence cut by the end of a chunk is held back for the next one; a BOM at
/// the very start of the stream is dropped, as the SDK decoder does.
class ChunkedUtf8Decoder {
  Uint8List? _carry;

  var _atStart = true;

  var _units = Uint16List(4096);

  /// Decodes the next chunk of the stream.
  String convert(Uint8List chunk) {
    var bytes = chunk;
    if (_carry case final carry?) {
      bytes = Uint8List(carry.length + chunk.length)
        ..setRange(0, carry.length, carry)
        ..setRange(carry.length, carry.length + chunk.length, chunk);
      _carry = null;
    }
    var end = bytes.length;
    final tail = _incompleteTail(bytes);
    if (tail < end) {
      _carry = Uint8List.fromList(bytes.sublist(tail));
      end = tail;
    }
    var start = 0;
    if (_atStart && end > 0) {
      _atStart = false;
      if (_isBom(bytes, 0, end)) start = 3;
    }
    if (start >= end) return '';
    return _decode(bytes, start, end);
  }

  /// Ends the stream: a sequence still held back decodes as the SDK decoder
  /// would decode it at the end.
  String close() {
    final carry = _carry;
    if (carry == null) return '';
    _carry = null;
    return _convertStretch(carry, 0, carry.length);
  }

  static bool _isBom(Uint8List bytes, int start, int end) =>
      end - start >= 3 &&
      bytes[start] == 0xef &&
      bytes[start + 1] == 0xbb &&
      bytes[start + 2] == 0xbf;

  /// The SDK's conversion of `bytes[start..end)`, except that it keeps the
  /// BOMs at [start]: `convert` drops one at the start of any range, a chunked
  /// decoder only at the start of the stream.
  static String _convertStretch(Uint8List bytes, int start, int end) {
    if (!_isBom(bytes, start, end)) return _sdk.convert(bytes, start, end);
    var boms = 0;
    while (_isBom(bytes, start, end)) {
      boms++;
      start += 3;
    }
    return '\ufeff' * boms + _sdk.convert(bytes, start, end);
  }

  String _decode(Uint8List bytes, int start, int end) {
    final words = ByteData.sublistView(bytes);

    var nonAsciiWords = 0;
    for (var i = start; i + 4 <= end && i < start + 64; i += 4) {
      if (words.getUint32(i, Endian.little) & 0x80808080 != 0) nonAsciiWords++;
    }
    if (nonAsciiWords >= 4) return _decodeUnits(bytes, start, end);

    final parts = <String>[];
    var asciiBytes = 0;
    var stretches = 0;
    var i = start;
    while (i < end) {
      final runStart = i;
      while (
          i + 4 <= end && words.getUint32(i, Endian.little) & 0x80808080 == 0) {
        i += 4;
      }
      while (i < end && bytes[i] < 0x80) {
        i++;
      }
      if (i > runStart) {
        parts.add(String.fromCharCodes(bytes, runStart, i));
        asciiBytes += i - runStart;
      }
      if (i >= end) break;

      // The ASCII runs between stretches have turned out short: the rest of
      // the chunk is dense after all.
      if (++stretches > 4 && asciiBytes < stretches * 64) {
        parts.add(_decodeUnits(bytes, i, end));
        break;
      }
      // An ASCII byte never continues a sequence, so a stretch of non-ASCII
      // bytes is whole sequences, malformed ones included.
      final stretchStart = i;
      while (i < end && bytes[i] >= 0x80) {
        i++;
      }
      parts.add(_convertStretch(bytes, stretchStart, i));
    }
    return parts.length == 1 ? parts[0] : parts.join();
  }

  /// Decodes valid UTF-8 into UTF-16 code units, and hands the rest of the
  /// range to the SDK from the first malformed byte on. [end] never cuts a
  /// valid sequence: an incomplete one there was held back.
  String _decodeUnits(Uint8List bytes, int start, int end) {
    if (_units.length < end - start) _units = Uint16List(end - start + 1024);
    final units = _units;
    var n = 0;
    var i = start;
    while (i < end) {
      final b0 = bytes[i];
      if (b0 < 0x80) {
        units[n++] = b0;
        i++;
        continue;
      }
      if (b0 < 0xe0) {
        if (b0 >= 0xc2 && i + 1 < end) {
          final b1 = bytes[i + 1];
          if (b1 & 0xc0 == 0x80) {
            units[n++] = (b0 & 0x1f) << 6 | b1 & 0x3f;
            i += 2;
            continue;
          }
        }
      } else if (b0 < 0xf0) {
        if (i + 2 < end) {
          final b1 = bytes[i + 1], b2 = bytes[i + 2];
          final codePoint = (b0 & 0x0f) << 12 | (b1 & 0x3f) << 6 | b2 & 0x3f;
          // Both continuation bytes, then no overlong form and no surrogate.
          if ((b1 & 0xc0 | (b2 & 0xc0) >> 2) == 0xa0 &&
              codePoint >= 0x800 &&
              codePoint & 0xf800 != 0xd800) {
            units[n++] = codePoint;
            i += 3;
            continue;
          }
        }
      } else if (b0 < 0xf5 && i + 3 < end) {
        final b1 = bytes[i + 1], b2 = bytes[i + 2], b3 = bytes[i + 3];
        final codePoint = (b0 & 0x07) << 18 |
            (b1 & 0x3f) << 12 |
            (b2 & 0x3f) << 6 |
            b3 & 0x3f;
        if ((b1 & 0xc0 | (b2 & 0xc0) >> 2 | (b3 & 0xc0) >> 4) == 0xa8 &&
            codePoint >= 0x10000 &&
            codePoint <= 0x10ffff) {
          units[n++] = 0xd7c0 + (codePoint >> 10);
          units[n++] = 0xdc00 | codePoint & 0x3ff;
          i += 4;
          continue;
        }
      }
      return String.fromCharCodes(units, 0, n) + _convertStretch(bytes, i, end);
    }
    return String.fromCharCodes(units, 0, n);
  }

  /// Where a valid but incomplete sequence at the end of [bytes] starts, or
  /// `bytes.length` if there is none. An invalid one is left for the SDK to
  /// replace now, as a chunked SDK decoder replaces it.
  static int _incompleteTail(Uint8List bytes) {
    final end = bytes.length;
    for (var t = end - 1; t >= 0 && t >= end - 3; t--) {
      final lead = bytes[t];
      if (lead < 0x80) return end;
      if (lead < 0xc0) continue;
      final length = lead < 0xc2
          ? 0
          : lead < 0xe0
              ? 2
              : lead < 0xf0
                  ? 3
                  : lead < 0xf5
                      ? 4
                      : 0;
      if (length == 0 || t + length <= end) return end;
      for (var k = t + 1; k < end; k++) {
        final byte = bytes[k];
        final valid = k == t + 1
            ? switch (lead) {
                0xe0 => byte >= 0xa0 && byte <= 0xbf,
                0xed => byte >= 0x80 && byte <= 0x9f,
                0xf0 => byte >= 0x90 && byte <= 0xbf,
                0xf4 => byte >= 0x80 && byte <= 0x8f,
                _ => byte & 0xc0 == 0x80,
              }
            : byte & 0xc0 == 0x80;
        if (!valid) return end;
      }
      return t;
    }
    return end;
  }
}
