import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xterm3/src/utils/utf8_decoder.dart';

/// What a chunked `Utf8Decoder(allowMalformed: true)` makes of [chunks].
String sdkDecode(List<Uint8List> chunks) {
  final out = StringBuffer();
  final sink = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(StringConversionSink.withCallback(out.write));
  for (final chunk in chunks) {
    sink.add(chunk);
  }
  sink.close();
  return out.toString();
}

String decode(List<Uint8List> chunks) {
  final decoder = ChunkedUtf8Decoder();
  final out = StringBuffer();
  for (final chunk in chunks) {
    out.write(decoder.convert(chunk));
  }
  out.write(decoder.close());
  return out.toString();
}

List<Uint8List> split(List<int> bytes, Random random, int maxChunk) {
  final chunks = <Uint8List>[];
  var i = 0;
  while (i < bytes.length) {
    final n = random.nextInt(maxChunk + 1); // 0: an empty chunk now and then
    final end = min(i + n, bytes.length);
    chunks.add(Uint8List.fromList(bytes.sublist(i, end)));
    i = end;
  }
  return chunks;
}

void main() {
  // Valid pieces of every length and density, and the malformed ones the SDK
  // has rules for: lone continuations, overlong forms, surrogates, code points
  // past U+10FFFF, bytes that never occur, sequences cut short.
  final valid = [
    'a',
    'hello world ',
    '\r\n',
    'é',
    'ğüşıöç',
    'стр',
    '—',
    '’',
    '…',
    '€',
    '中文',
    'かな',
    '한국',
    '、。',
    'Ａ',
    '😀',
    '👨‍👩‍👧',
    '🇹🇷',
    '\u{10ffff}',
    '﻿',
    '\u{0301}',
    '─│',
    'ab\u0000c',
  ];
  final malformed = <List<int>>[
    [0x80],
    [0xbf],
    [0xc0, 0x80],
    [0xc1, 0xbf],
    [0xe0, 0x80, 0x80],
    [0xed, 0xa0, 0x80],
    [0xf0, 0x80, 0x80, 0x80],
    [0xf4, 0x90, 0x80, 0x80],
    [0xf5],
    [0xff],
    [0xfe],
    [0xe2, 0x82],
    [0xf0, 0x9f, 0x98],
    [0xc3],
    [0xef, 0xbb],
    [0xe2, 0x41],
    [0xf0, 0x9f, 0x41],
  ];

  List<int> randomStream(Random random, {required bool dense}) {
    final bytes = <int>[];
    if (random.nextInt(4) == 0) bytes.addAll([0xef, 0xbb, 0xbf]);
    final pieces = random.nextInt(400);
    for (var k = 0; k < pieces; k++) {
      if (random.nextInt(dense ? 6 : 40) == 0) {
        bytes.addAll(malformed[random.nextInt(malformed.length)]);
      } else if (!dense && random.nextInt(4) != 0) {
        bytes.addAll(utf8.encode('x' * random.nextInt(200)));
      } else {
        bytes.addAll(utf8.encode(valid[random.nextInt(valid.length)]));
      }
    }
    return bytes;
  }

  test('decodes as a chunked SDK decoder does, valid and malformed', () {
    final random = Random(2026);
    for (var round = 0; round < 3000; round++) {
      final bytes = randomStream(random, dense: round.isOdd);
      for (final maxChunk in [1, 3, 7, 64, 1024, 70000]) {
        final chunks = split(bytes, random, maxChunk);
        expect(decode(chunks), sdkDecode(chunks),
            reason: 'round $round, chunks of up to $maxChunk: $bytes');
      }
    }
  });

  test('keeps a BOM after the start and drops one at the start', () {
    final bom = [0xef, 0xbb, 0xbf];
    for (final bytes in [
      [...bom, 0x41],
      [0x41, ...bom, 0x42],
      [...bom, ...bom],
      [0xc3, 0xa9, ...bom],
    ]) {
      for (var cut = 0; cut <= bytes.length; cut++) {
        final chunks = [
          Uint8List.fromList(bytes.sublist(0, cut)),
          Uint8List.fromList(bytes.sublist(cut)),
        ];
        expect(decode(chunks), sdkDecode(chunks), reason: '$bytes cut $cut');
      }
    }
  });

  test('holds back a character split across chunks', () {
    final decoder = ChunkedUtf8Decoder();
    final bytes = utf8.encode('a😀b');
    expect(decoder.convert(Uint8List.fromList(bytes.sublist(0, 3))), 'a');
    expect(decoder.convert(Uint8List.fromList(bytes.sublist(3))), '😀b');
    expect(decoder.close(), '');
  });

  test('takes dense and mostly-ASCII chunks alike', () {
    // 1 KiB chunks of each kind, so both ways through a chunk are taken, and
    // the switch from one to the other inside a chunk.
    final text = StringBuffer();
    final random = Random(7);
    for (var line = 0; line < 2000; line++) {
      text
        ..write(switch (line % 4) {
          0 => 'plain ascii line with a café and — dash ' * 3,
          1 => '中文字符かなカナ한국어、。' * 6,
          2 => 'ascii first ' * 6 + '😀🚀🔥' * 20,
          _ => 'şöyle bir Türkçe satır ğüşıöç ' * 3,
        })
        ..write('\r\n');
    }
    final bytes = utf8.encode(text.toString());
    for (final maxChunk in [1024, 4096]) {
      final chunks = split(bytes, random, maxChunk);
      expect(decode(chunks), sdkDecode(chunks));
    }
  });
}
