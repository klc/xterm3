// End-to-end throughput target for script/term_compare/run.sh: runs the
// command in XB_ARGS ('|'-separated) in a real PTY, in an XB_W x XB_H box
// (800x600 is 100x37 cells), and exits when it does.
//
// XB_NOVIEW=1 mounts no TerminalView (the terminal is sized to 100x37 by
// hand), so the run is PTY + decode + Terminal.write with no layout or paint.
// XB_PROF=<file> appends one JSON line at exit: DSR reply times with the
// accumulated time inside terminal.write and write-call count at each, and every FrameTiming
// (build start, build and raster duration). Both off by default.
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_pty2/flutter_pty.dart';
import 'package:xterm3/xterm.dart';

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

void main() => runApp(const MaterialApp(home: _Bench()));

class _Bench extends StatefulWidget {
  const _Bench();
  @override
  State<_Bench> createState() => _BenchState();
}

class _BenchState extends State<_Bench> {
  final terminal = Terminal(maxLines: 10000, platform: TerminalTargetPlatform.macos);

  @override
  void initState() {
    super.initState();
    if (_noView) terminal.resize(100, 37);
    if (_prof != null) {
      WidgetsBinding.instance.addTimingsCallback((ts) => _frames.addAll(ts.map((t) => [
            t.timestampInMicroseconds(FramePhase.buildStart),
            t.buildDuration.inMicroseconds,
            t.rasterDuration.inMicroseconds,
          ])));
    }
    WidgetsBinding.instance.endOfFrame.then((_) {
      final pty = Pty.start('/usr/bin/python3',
          arguments: _args.split('|'),
          columns: terminal.viewWidth,
          rows: terminal.viewHeight);
      final decoded = pty.output.cast<List<int>>().transform(const Utf8Decoder());
      if (_prof == null) {
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
        if (_prof != null) _replies.add([Timeline.now, _writeSw.elapsedMicroseconds, _writes]);
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
              '${jsonEncode({'view': !_noView, 'replies': _replies, 'frames': _frames})}\n',
              mode: FileMode.append);
        }
        exit(0);
      });
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: _w, height: _h, child: _noView ? null : TerminalView(terminal)),
        ),
      );
}
