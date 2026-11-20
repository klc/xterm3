// e2e_bench.dart's harness on flutter_pty2 3.x (Pty.spawn / PtySession). Throwaway
// bench code; builds only copied into example/lib/ with an untracked
// example/pubspec_overrides.yaml that points flutter_pty2 at a 3.x checkout
// (recipe: script/term_compare/spike_pty3.sh). Same env and XB_PROF record shape:
// XB_W, XB_H, XB_ARGS ('|'-separated), XB_PROF=<file>.
// Configs: none / XB_LEVER=1 unpaced (chunk -> decode -> terminal.write; flow
// control is the plugin's 256 KiB output window). XB_PACED=1 routes output
// through PacedTerminalWriter (unbounded queue). XB_PAUSE=1 (with XB_PACED=1)
// pauses the output subscription - which withholds the plugin's credit - while
// more than _pauseAbove PTY bytes are queued in the writer, and resumes once
// they are below _resumeBelow.
// Reply record: [now, write us, writes, chunks, pendMax, rssMax, maxRss,
// qUnitsMax, qBytesMax]: as e2e_bench.dart, plus peak queued UTF-16 units and
// peak queued PTY (UTF-8) bytes in the writer since the previous reply.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:xterm3/xterm.dart';

final _env = Platform.environment;
final _w = double.parse(_env['XB_W'] ?? '800');
final _h = double.parse(_env['XB_H'] ?? '600');
final _args = _env['XB_ARGS'] ?? '';
final _prof = _env['XB_PROF'];
final _paced = _env['XB_PACED'] == '1';
final _pause = _paced && _env['XB_PAUSE'] == '1';
const _pauseAbove = 1 << 20,
    _resumeBelow = 256 << 10; // PTY bytes queued in the writer
final _writeSw = Stopwatch();
var _writes = 0,
    _chunks = 0,
    _pendMax = 0,
    _rssMax = 0,
    _qUnitsMax = 0,
    _qBytesMax = 0,
    _pauses = 0;
final _replies = <List<int>>[];
final _frames = <List<int>>[];

// What was handed to the writer and not yet written: (UTF-8 bytes, UTF-16
// units) per chunk, FIFO like the writer's own queue.
final _q = Queue<(int, int)>();
var _qBytes = 0, _qUnits = 0;
StreamSubscription<Uint8List>? _sub;

class _Sink implements Sink<String> {
  _Sink(this.f);
  final void Function(String) f;
  @override
  void add(String s) => f(s);
  @override
  void close() {}
}

class _TimedTerminal extends Terminal {
  _TimedTerminal()
      : super(maxLines: 10000, platform: TerminalTargetPlatform.macos);
  @override
  void write(String data) {
    _writes++;
    _writeSw.start();
    super.write(data);
    _writeSw.stop();
    // Every write comes from the writer's FIFO when paced.
    if (_paced && _q.isNotEmpty) {
      final (b, u) = _q.removeFirst();
      _qBytes -= b;
      _qUnits -= u;
      if (_pause && _sub!.isPaused && _qBytes < _resumeBelow) _sub!.resume();
    }
  }
}

void main() => runApp(const MaterialApp(home: _Bench()));

class _Bench extends StatefulWidget {
  const _Bench();
  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final terminal = _TimedTerminal();

  @override
  void initState() {
    super.initState();
    if (_prof != null) {
      WidgetsBinding.instance
          .addTimingsCallback((ts) => _frames.addAll(ts.map((t) => [
                t.timestampInMicroseconds(FramePhase.buildStart),
                t.buildDuration.inMicroseconds,
                t.rasterDuration.inMicroseconds,
              ])));
    }
    WidgetsBinding.instance.endOfFrame.then((_) => _start());
  }

  Future<void> _dumpAndExit() async {
    if (_prof != null) {
      // FrameTimings arrive in batches; draw a few more frames to flush them.
      for (var i = 0; i < 20; i++) {
        WidgetsBinding.instance.scheduleFrame();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      File(_prof!).writeAsStringSync(
          '${jsonEncode({
                'view': true,
                'mode': ['pty3', _paced, _pause, _pauseAbove, _resumeBelow],
                'pauses': _pauses,
                'replies': _replies,
                'frames': _frames,
                'screen': [
                  for (var y = 0; y < 3; y++)
                    terminal.buffer.lines[terminal.buffer.scrollBack + y]
                        .getText()
                ]
              })}\n',
          mode: FileMode.append);
    }
    exit(0);
  }

  Future<void> _start() async {
    final session = await Pty.spawn(PtySpawnOptions(
      executable: '/usr/bin/python3',
      arguments: _args.split('|'),
      size: PtySize(columns: terminal.viewWidth, rows: terminal.viewHeight),
    ));
    final writer = _paced ? PacedTerminalWriter(terminal) : null;
    var chunkBytes = 0, sinceRss = 0;
    // Chunked: a multi-byte character can be split across PTY chunks.
    final dec = const Utf8Decoder().startChunkedConversion(_Sink((s) {
      if (writer == null) return terminal.write(s);
      if (s.isEmpty) return; // the writer drops these; keep the FIFO in step
      writer.write(s);
      _q.add((chunkBytes, s.length));
      _qBytes += chunkBytes;
      _qUnits += s.length;
      if (writer.pendingChunks > _pendMax) _pendMax = writer.pendingChunks;
      if (_qBytes > _qBytesMax) _qBytesMax = _qBytes;
      if (_qUnits > _qUnitsMax) _qUnitsMax = _qUnits;
      if (_pause && !_sub!.isPaused && _qBytes > _pauseAbove) {
        _pauses++;
        _sub!.pause();
      }
    }));
    _sub = session.output.listen((b) {
      _chunks++;
      // RSS every >= 64 KiB of output: every 64 chunks on the 1.x bench.
      if ((sinceRss += b.length) >= 64 << 10) {
        sinceRss = 0;
        final r = ProcessInfo.currentRss;
        if (r > _rssMax) _rssMax = r;
      }
      chunkBytes =
          b.length; // the decoder emits this chunk's text synchronously
      dec.add(b);
    });
    terminal.onOutput = (d) {
      if (_prof != null) {
        _replies.add([
          Timeline.now,
          _writeSw.elapsedMicroseconds,
          _writes,
          _chunks,
          _pendMax,
          _rssMax,
          ProcessInfo.maxRss,
          _qUnitsMax,
          _qBytesMax
        ]);
        _pendMax = 0;
        _qUnitsMax = 0;
        _qBytesMax = 0;
        _rssMax = 0;
      }
      unawaited(session.input.writeUtf8(d));
    };
    terminal.onResize =
        (w, h, pw, ph) => session.resize(PtySize(columns: w, rows: h));
    session.done.then((_) => _dumpAndExit());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: _w, height: _h, child: TerminalView(terminal)),
        ),
      );
}
