// XB_ISO=1 worker for e2e_bench.dart (throwaway spike code): owns the PTY and
// a headless Terminal, answers DSR itself, and serves snapshots of the visible
// grid. No Flutter here - package:xterm3/core.dart only.
//
// The PTY runs with ackRead and is acked after each chunk is parsed (or on
// arrival with XB_ACK=2), so at most one PTY message sits in this isolate's
// queue and a snapshot request waits behind at most one chunk.
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_pty2/flutter_pty.dart';
import 'package:xterm3/core.dart';

const isoCols = 100, isoRows = 37;

class _Sink implements Sink<String> {
  _Sink(this.f);
  final void Function(String) f;
  @override
  void add(String s) => f(s);
  @override
  void close() {}
}

/// a = [SendPort toUi, String xbArgs, bool ackEarly, bool push]
///
/// push (XB_ISO=2): no ackRead at all - the PTY backlog is unbounded in this
/// isolate's queue, so requests would wait behind it; instead the chunk handler
/// pushes a snapshot whenever 13 ms have passed since the last one.
void isoMain(List<Object?> a) {
  final ui = a[0] as SendPort;
  final args = a[1] as String;
  final early = a[2] as bool;
  final push = a[3] as bool;
  var lastPush = 0;
  final terminal =
      Terminal(maxLines: 10000, platform: TerminalTargetPlatform.macos)
        ..resize(isoCols, isoRows);
  final sw = Stopwatch();
  var writes = 0, chunks = 0, rssMax = 0;
  final replies = <List<int>>[];
  final pty = Pty.start('/usr/bin/python3',
      arguments: args.split('|'),
      columns: isoCols,
      rows: isoRows,
      ackRead: !push);
  final dec = const Utf8Decoder().startChunkedConversion(_Sink((s) {
    writes++;
    sw.start();
    terminal.write(s);
    sw.stop();
  }));
  late final void Function(int) snap;
  pty.output.listen((b) {
    if (chunks++ % 64 == 0) {
      final r = ProcessInfo.currentRss;
      if (r > rssMax) rssMax = r;
    }
    if (push) {
      dec.add(b);
      final now = Timeline.now;
      if (now - lastPush >= 13000) {
        lastPush = now;
        snap(now);
      }
      return;
    }
    if (early) pty.ackRead();
    dec.add(b);
    if (!early) pty.ackRead();
  });
  terminal.onOutput = (d) {
    // same fields as the UI-side XB_PROF replies, plus chunks, window rss max, maxRss
    replies.add([
      Timeline.now,
      sw.elapsedMicroseconds,
      writes,
      chunks,
      0,
      rssMax,
      ProcessInfo.maxRss
    ]);
    rssMax = 0;
    pty.write(const Utf8Encoder().convert(d));
  };
  final rp = ReceivePort();
  // m = request time (Timeline.now on the UI side), or push time
  snap = (m) {
    final t0 = Timeline.now;
    final buf = terminal.buffer;
    final cells = Uint32List(isoCols * isoRows * 4);
    for (var y = 0; y < isoRows; y++) {
      final line = buf.lines[buf.scrollBack + y];
      for (var x = 0, o = y * isoCols * 4; x < isoCols; x++, o += 4) {
        cells[o] = line.getForeground(x);
        cells[o + 1] = line.getBackground(x);
        cells[o + 2] = line.getAttributes(x);
        cells[o + 3] = line.getContent(x);
      }
    }
    final ttd = TransferableTypedData.fromList([cells]);
    ui.send([
      m,
      t0,
      Timeline.now - t0,
      ttd,
      buf.cursorX,
      buf.cursorY,
      terminal.viewWidth,
      terminal.viewHeight
    ]);
  };
  rp.listen((m) {
    if (!push) snap(m as int);
  });
  ui.send(rp.sendPort);
  pty.exitCode.then((_) {
    ui.send(['exit', replies]);
    rp.close();
  });
}
