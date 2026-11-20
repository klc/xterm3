// End-to-end throughput target for script/term_compare/run.sh: runs the
// command in XB_ARGS ('|'-separated) in a real PTY, in an XB_W x XB_H box
// (800x600 is 100x37 cells), and exits when it does.
//
// XB_NOVIEW=1 mounts no TerminalView (the terminal is sized to 100x37 by
// hand), so the run is PTY + decode + Terminal.write with no layout or paint.
// XB_PROF=<file> appends one JSON line at exit: DSR reply times with the
// accumulated time inside terminal.write and write-call count at each, and every FrameTiming
// (build start, build and raster duration). Both off by default.
//
// Spike levers (throwaway bench code; with none set the path above is unchanged):
// XB_ACK=1 starts the PTY with ackRead and acks after each chunk is parsed;
// XB_ACK=2 acks on arrival, before parsing (one chunk read ahead).
// XB_PACED=2 (paced-span, no ack): per-frame budget XB_BUDGET_MS (default 8)
// spanning event-loop turns; chunks past the budget are queued and drained
// after the frame. Prof adds max queued chunks (pendMax slot) and max queued
// UTF-16 code units (index 7).
// XB_PACED=3 (paced-noframe): PacedTerminalWriter whose frame wait never
// completes, so after its first timeout it drains as if frames had stopped -
// while the window keeps producing them.
// XB_PACED=1 routes output through PacedTerminalWriter. Both: ack at once while
// pendingChunks < XB_ACK_BELOW (default 2048), otherwise re-check after each
// frame's drain pass. XB_LEVER=1 is today's unpaced path through the same
// decode sink and counters, for comparison. XB_ISO=1: e2e_worker.dart owns PTY + parsing; the UI
// pulls a 100x37 snapshot per frame into a mirror Terminal shown by TerminalView;
// XB_ISO=2: worker un-acked, pushes a snapshot from its chunk handler every >=13 ms.
// With XB_PROF these add per reply: chunks, max pendingChunks, max currentRss
// (sampled every 64 chunks) since the previous reply, maxRss; and for XB_ISO
// every snapshot: [request, worker build start, build us, received, apply us].
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_pty2/flutter_pty.dart';
import 'package:flutter/scheduler.dart';
import 'package:xterm3/xterm.dart';

import 'e2e_worker.dart';

final _env = Platform.environment;
final _w = double.parse(_env['XB_W'] ?? '800');
final _h = double.parse(_env['XB_H'] ?? '600');
final _args = _env['XB_ARGS'] ?? '';
final _noView = _env['XB_NOVIEW'] == '1';
final _prof = _env['XB_PROF'];
final _writeSw = Stopwatch();
var _writes = 0;
final _replies = <List<int>>[];
final _frames = <List<int>>[];
final _ack = _env['XB_ACK'] == '1' || _env['XB_ACK'] == '2';
final _ackEarly =
    _env['XB_ACK'] == '2'; // ack on arrival, before parsing (unpaced / isolate)
final _paced = _env['XB_PACED'] == '1' || _env['XB_PACED'] == '3';
final _noFrame = _env['XB_PACED'] == '3';
final _span = _env['XB_PACED'] ==
    '2'; // paced-span: per-frame budget across event-loop turns, no ack
final _budgetUs = (double.parse(_env['XB_BUDGET_MS'] ?? '8') * 1000).round();
final _iso = _env['XB_ISO'] == '1' || _env['XB_ISO'] == '2';
final _isoPush =
    _env['XB_ISO'] == '2'; // worker un-acked, pushes snapshots every >=13 ms
final _lever = _ack ||
    _paced ||
    _span ||
    _env['XB_LEVER'] == '1'; // XB_LEVER=1: unpaced, no ack, lever code path
final _ackBelow = int.parse(_env['XB_ACK_BELOW'] ?? '2048');
var _chunks = 0, _pendMax = 0, _rssMax = 0, _qUnitsMax = 0;
final _snaps = <List<int>>[];
// XB_STATS=1 (with XB_PROF): after every frame, cumulative TerminalRenderStats,
// write count and a hash of the top visible line; frames then also carry their
// frameNumber so the two can be joined.
final _statsOn = _env['XB_STATS'] == '1';
final _stats = <List<int>>[];
// XB_MEM='<results>|<term>|<file>|...' (glue attribution, no PTY): each file,
// LF turned into CRLF as the PTY's ONLCR does, is written to Terminal.write in
// XB_CHUNK-byte chunks (default 1024) through a chunked Utf8Decoder, in one
// synchronous loop, and one drive.py-shaped JSON line per file goes to
// <results>. (Feeding the chunks from a helper isolate through a ReceivePort was
// tried and cost ~0.9 ms per message, where the PTY plugin's messages cost
// ~12 us, so it does not stand for the plugin and was removed.)
// XB_BYTES=1: PTY output goes to Terminal.writeBytes instead of through a
// Utf8Decoder transform into Terminal.write (the default path only).
final _bytes = _env['XB_BYTES'] == '1';
final _mem = _env['XB_MEM'];
final _memChunk = int.parse(_env['XB_CHUNK'] ?? '1024');
// XB_MAXLINES=<n>: scrollback of the default terminal (10000).
final _maxLines = int.parse(_env['XB_MAXLINES'] ?? '10000');
// XB_MEM_WAIT=<s>: waits that long before the first file and after the last,
// so a profiler can attach to the VM service and collect samples.
final _memWait = Duration(seconds: int.parse(_env['XB_MEM_WAIT'] ?? '0'));

Uint8List _onlcr(Uint8List b) {
  var lf = 0;
  for (final c in b) {
    if (c == 10) lf++;
  }
  final o = Uint8List(b.length + lf);
  var j = 0;
  for (final c in b) {
    if (c == 10) o[j++] = 13;
    o[j++] = c;
  }
  return o;
}

// XB_SHOT=<file> (pixel oracle, no PTY): writes the file into the terminal,
// optionally selects XB_SEL="x1,y1,x2,y2", waits a few frames and saves the
// view as a PNG to XB_SHOT_OUT, rendered at XB_DPR (default 1). The DPR also
// overrides MediaQuery, so the painter snaps cells to the same ratio. Prints
// one JSON line (dpr, isShaderFilterSupported = Impeller) and exits.
final _shot = _env['XB_SHOT'];
final _shotDpr = double.parse(_env['XB_DPR'] ?? '1');
final _shotKey = GlobalKey();
final _shotCtl = TerminalController();

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
  }
}

void main() => runApp(const MaterialApp(home: _Bench()));

class _Bench extends StatefulWidget {
  const _Bench();
  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final terminal = _lever
      ? _TimedTerminal()
      : Terminal(
          maxLines: _iso ? 100 : _maxLines,
          platform: TerminalTargetPlatform.macos);

  @override
  void initState() {
    super.initState();
    if (_noView) terminal.resize(100, 37);
    if (_prof != null) {
      WidgetsBinding.instance
          .addTimingsCallback((ts) => _frames.addAll(ts.map((t) => [
                t.timestampInMicroseconds(FramePhase.buildStart),
                t.buildDuration.inMicroseconds,
                t.rasterDuration.inMicroseconds,
                if (_statsOn) t.frameNumber,
              ])));
      if (_statsOn) {
        SchedulerBinding.instance.addPersistentFrameCallback((_) {
          final b = terminal.buffer;
          _stats.add([
            PlatformDispatcher.instance.frameData.frameNumber,
            Timeline.now,
            _writes,
            TerminalRenderStats.paints,
            TerminalRenderStats.paintedLines,
            TerminalRenderStats.paragraphCacheHits,
            TerminalRenderStats.paragraphCacheMisses,
            TerminalRenderStats.glyphCacheHits,
            TerminalRenderStats.glyphCacheMisses,
            b.lines[b.scrollBack].getText().hashCode,
          ]);
        });
      }
    }
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (_shot != null) return unawaited(_takeShot());
      if (_iso) return unawaited(_startIso());
      if (_mem != null) return unawaited(_runMem());
      if (_lever) return _startLevers();
      final pty = Pty.start('/usr/bin/python3',
          arguments: _args.split('|'),
          columns: terminal.viewWidth,
          rows: terminal.viewHeight);
      final decoded =
          pty.output.cast<List<int>>().transform(const Utf8Decoder());
      if (_bytes) {
        pty.output.listen((b) => terminal.writeBytes(b));
      } else if (_prof == null) {
        decoded.listen(terminal.write);
      } else {
        decoded.listen((s) {
          _writes++;
          _writeSw.start();
          terminal.write(s);
          _writeSw.stop();
        });
      }
      terminal.onOutput = (d) {
        if (_prof != null) {
          _replies.add([Timeline.now, _writeSw.elapsedMicroseconds, _writes]);
        }
        pty.write(const Utf8Encoder().convert(d));
      };
      terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
      pty.exitCode.then((_) async {
        if (_prof != null) {
          // FrameTimings arrive in batches; draw a few more frames to flush them.
          for (var i = 0; i < 20; i++) {
            WidgetsBinding.instance.scheduleFrame();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          File(_prof!).writeAsStringSync(
              '${jsonEncode({
                    'view': !_noView,
                    'replies': _replies,
                    'frames': _frames
                  })}\n',
              mode: FileMode.append);
        }
        exit(0);
      });
    });
  }

  Future<void> _runMem() async {
    final parts = _mem!.split('|');
    await Future<void>.delayed(_memWait);
    for (final path in parts.skip(2)) {
      terminal.write('\x1b[?1049l\x1b[0m\x1b[H\x1b[2J');
      await WidgetsBinding.instance.endOfFrame;
      final sw = Stopwatch();
      final dec =
          const Utf8Decoder().startChunkedConversion(_Sink(terminal.write));
      final b = _onlcr(File(path).readAsBytesSync());
      sw.start();
      for (var i = 0; i < b.length; i += _memChunk) {
        dec.add(Uint8List.sublistView(b, i, min(i + _memChunk, b.length)));
      }
      dec.close();
      sw.stop();
      final size = File(path).lengthSync();
      File(parts[0]).writeAsStringSync(
          '${jsonEncode({
                'term': parts[1],
                'payload': path.split('/').last,
                'size': size,
                'cols': terminal.viewWidth,
                'rows': terminal.viewHeight,
                'parsed': sw.elapsedMicroseconds / 1e6,
                'mibs': size / 1048576 / (sw.elapsedMicroseconds / 1e6),
              })}\n',
          mode: FileMode.append);
    }
    await Future<void>.delayed(_memWait);
    exit(0);
  }

  Future<void> _takeShot() async {
    terminal.write(File(_shot!).readAsStringSync());
    final sel = _env['XB_SEL'];
    if (sel != null) {
      final v = sel.split(',').map(int.parse).toList();
      final b = terminal.buffer;
      _shotCtl.setSelection(b.createAnchor(v[0], b.scrollBack + v[1]),
          b.createAnchor(v[2], b.scrollBack + v[3]));
    }
    for (var i = 0; i < 4; i++) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
    }
    final boundary =
        _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: _shotDpr);
    final png = await image.toByteData(format: ImageByteFormat.png);
    File(_env['XB_SHOT_OUT']!).writeAsBytesSync(png!.buffer.asUint8List());
    stdout.writeln(jsonEncode({
      'dpr': _shotDpr,
      'impeller': ImageFilter.isShaderFilterSupported,
      'size': [image.width, image.height],
    }));
    exit(0);
  }

  Future<void> _dumpAndExit() async {
    if (_prof != null) {
      for (var i = 0; i < 20; i++) {
        WidgetsBinding.instance.scheduleFrame();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      File(_prof!).writeAsStringSync(
          '${jsonEncode({
                'view': !_noView,
                'mode': [_ack, _paced, _iso, _ackBelow],
                'replies': _replies,
                'frames': _frames,
                'snaps': _snaps,
                if (_statsOn) 'stats': _stats,
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

  void _startLevers() {
    final pty = Pty.start('/usr/bin/python3',
        arguments: _args.split('|'),
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
        ackRead: _ack);
    final writer = _paced
        ? PacedTerminalWriter(terminal,
            waitForFrame: _noFrame ? () => Completer<void>().future : null)
        : null;
    // paced-span: write on arrival until this frame's budget is spent, then
    // only enqueue; after the frame, reset and drain until the budget is spent
    // again. A persistent frame callback also resets the total every frame.
    final q = Queue<String>();
    var qUnits = 0, spent = 0, waiting = false;
    final slice = Stopwatch();
    void timedWrite(String s) {
      slice
        ..reset()
        ..start();
      terminal.write(s);
      spent += slice.elapsedMicroseconds;
    }

    late void Function() drain;
    void waitFrame() {
      if (waiting) return;
      waiting = true;
      SchedulerBinding.instance.endOfFrame.then((_) {
        waiting = false;
        spent = 0;
        drain();
      });
    }

    drain = () {
      while (q.isNotEmpty && spent < _budgetUs) {
        final s = q.removeFirst();
        qUnits -= s.length;
        timedWrite(s);
      }
      if (spent >= _budgetUs || q.isNotEmpty) waitFrame();
    };
    if (_span) {
      SchedulerBinding.instance.addPersistentFrameCallback((_) => spent = 0);
    }
    final dec = const Utf8Decoder().startChunkedConversion(_Sink((s) {
      if (_span) {
        if (spent >= _budgetUs || q.isNotEmpty) {
          q.add(s);
          qUnits += s.length;
          if (q.length > _pendMax) _pendMax = q.length;
          if (qUnits > _qUnitsMax) _qUnitsMax = qUnits;
          return waitFrame();
        }
        timedWrite(s);
        if (spent >= _budgetUs) waitFrame();
        return;
      }
      if (writer == null) return terminal.write(s);
      writer.write(s);
      if (writer.pendingChunks > _pendMax) _pendMax = writer.pendingChunks;
    }));
    // paced+ack: one ack is owed per chunk; pay it while the queue is short,
    // else re-check after each frame (the microtask runs after the writer's
    // pass, which resumes on the same endOfFrame future).
    var owed = false;
    void check() {
      if (!owed) return;
      if (writer!.pendingChunks < _ackBelow) {
        owed = false;
        pty.ackRead();
      } else {
        SchedulerBinding.instance.endOfFrame
            .then((_) => scheduleMicrotask(check));
      }
    }

    pty.output.listen((b) {
      if (_chunks++ % 64 == 0) {
        final r = ProcessInfo.currentRss;
        if (r > _rssMax) _rssMax = r;
      }
      if (_ackEarly && writer == null) pty.ackRead();
      dec.add(b);
      if (!_ack || _ackEarly) return;
      if (writer == null) return pty.ackRead();
      owed = true;
      check();
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
          _qUnitsMax
        ]);
        _pendMax = 0;
        _qUnitsMax = 0;
        _rssMax = 0;
      }
      pty.write(const Utf8Encoder().convert(d));
    };
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
    pty.exitCode.then((_) => _dumpAndExit());
  }

  // XB_ISO: one snapshot request in flight; the next goes out after the frame
  // that painted the previous one.
  Future<void> _startIso() async {
    final rp = ReceivePort();
    late SendPort worker;
    void request() => worker.send(Timeline.now);
    rp.listen((m) {
      if (m is SendPort) {
        worker = m;
        request();
        return;
      }
      final l = m as List;
      if (l[0] == 'exit') {
        _replies.addAll((l[1] as List).map((e) => (e as List).cast<int>()));
        _dumpAndExit();
        return;
      }
      final recv = Timeline.now;
      final cells =
          (l[3] as TransferableTypedData).materialize().asUint32List();
      final cols = l[6] as int, rows = l[7] as int;
      assert(cols == terminal.viewWidth && rows == terminal.viewHeight);
      if (cols != terminal.viewWidth || rows != terminal.viewHeight) {
        stderr.writeln(
            'grid mismatch: worker ${cols}x$rows, view ${terminal.viewWidth}x${terminal.viewHeight}');
        exit(3);
      }
      final buf = terminal.buffer;
      for (var y = 0; y < rows; y++) {
        final line = buf.lines[buf.scrollBack + y];
        for (var x = 0, o = y * cols * 4; x < cols; x++, o += 4) {
          line.setForeground(x, cells[o]);
          line.setBackground(x, cells[o + 1]);
          line.setAttributes(x, cells[o + 2]);
          line.setContent(x, cells[o + 3]);
        }
      }
      terminal.setCursor(l[4] as int, l[5] as int);
      terminal.write(''); // notifies the view
      SchedulerBinding.instance.scheduleFrame();
      final applied = Timeline.now;
      if (_prof != null) {
        _snaps
            .add([l[0] as int, l[1] as int, l[2] as int, recv, applied - recv]);
      }
      if (!_isoPush) {
        SchedulerBinding.instance.addPostFrameCallback((_) => request());
      }
    });
    await Isolate.spawn(
        isoMain, <Object?>[rp.sendPort, _args, _ackEarly, _isoPush]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
              width: _w,
              height: _h,
              child: _noView
                  ? null
                  : _shot != null
                      ? MediaQuery(
                          data: MediaQuery.of(context)
                              .copyWith(devicePixelRatio: _shotDpr),
                          child: RepaintBoundary(
                              key: _shotKey,
                              child:
                                  TerminalView(terminal, controller: _shotCtl)))
                      : TerminalView(terminal)),
        ),
      );
}
