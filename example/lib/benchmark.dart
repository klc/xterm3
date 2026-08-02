// A deterministic render benchmark for A/B comparing two builds of xterm2.
//
// Run it in profile mode on both builds, with nothing else on screen:
//
//   cd example
//   flutter run --profile -t lib/benchmark.dart
//
// It drives the terminal with a fixed, precomputed byte stream - one write per
// frame - and reports UI and raster frame times per workload. There is no PTY
// and no shell, so two runs on the same machine see the same work.
//
// Compare the printed tables, not the DevTools FPS average. FPS conflates the
// two threads; the split is what tells you which bottleneck you are hitting:
//
//   UI high, raster low     -> parsing, paint recording, allocation
//   raster high, UI low     -> draw call count, glyph atlas, overdraw
//
// The `boxdraw` and `fullscreen` workloads run mostly through the procedural
// glyph path, which bypasses the paragraph cache entirely. `plain` and `sgr`
// are the cache-friendly text paths.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:xterm2/xterm.dart';

/// Frames written before measurement starts, to let caches and the shader
/// warm-up settle.
const _warmupFrames = 60;

/// Frames measured per workload.
const _measuredFrames = 400;

/// Fixed logical size for the terminal viewport. Pinning this rather than
/// filling the window is what makes two runs comparable - the cell count
/// drives every cost in the paint path.
const _viewportSize = Size(1000, 600);

const _frameBudgetMs = 1000 / 60;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenchmarkApp());
}

class BenchmarkApp extends StatelessWidget {
  const BenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: BenchmarkPage(),
    );
  }
}

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();

  final _collected = <FrameTiming>[];
  final _results = <_Result>[];

  /// Frames actually produced. `FrameTiming` callbacks are delivered
  /// asynchronously and in batches, so they cannot be used to count frames
  /// inside a window that has just closed - this counter can.
  var _frameCount = 0;

  var _status = 'starting';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    SchedulerBinding.instance.addPersistentFrameCallback((_) => _frameCount++);
    WidgetsBinding.instance.endOfFrame.then((_) => _run());
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _controller.dispose();
    _terminal.dispose();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    _collected.addAll(timings);
  }

  Future<void> _run() async {
    // Let layout settle so the terminal has been resized to the viewport.
    await _idle(10);

    final cols = _terminal.viewWidth;
    final rows = _terminal.viewHeight;
    _report('terminal grid: ${cols}x$rows (${cols * rows} cells), '
        'viewport ${_viewportSize.width.toInt()}x'
        '${_viewportSize.height.toInt()} logical px');
    _report('release mode: $kReleaseMode  profile mode: $kProfileMode');
    if (!kProfileMode && !kReleaseMode) {
      _report('WARNING: debug mode. Numbers are not comparable to a real '
          'build. Re-run with --profile.');
    }

    final total = _warmupFrames + _measuredFrames;
    await _runWorkload('plain', _plainFrames(total));
    await _runWorkload('sgr', _sgrFrames(total));
    await _runWorkload('boxdraw', _boxFrames(total));
    await _runWorkload(
      'fullscreen',
      _fullscreenFrames(total, rows, cols),
      enterAltScreen: true,
    );

    _printReport();
    await _runFlood();
  }

  /// The `cat bigfile` case. The four workloads above deliberately write once
  /// per frame, so they never test what happens when output arrives faster
  /// than frames can be produced. Here chunks are handed to `Terminal.write`
  /// as fast as the event loop will take them, exactly as a PTY stream
  /// listener does, and the interesting number is how many frames the UI still
  /// manages to produce while that is going on.
  Future<void> _runFlood() async {
    setState(() => _status = 'running flood');

    _terminal.write('\x1b[0m\x1b[2J\x1b[3J\x1b[H');
    await _idle(5);

    final chunk = _floodChunk();
    const chunkCount = 4096;
    final bytes = chunk.length * chunkCount;

    _collected.clear();
    final framesBefore = _frameCount;
    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < chunkCount; i++) {
      _terminal.write(chunk);
      // Yield the way a stream listener does, so frames get a chance to run
      // between chunks if the pipeline is not starved.
      await Future<void>.delayed(Duration.zero);
    }
    stopwatch.stop();
    final elapsedMs = stopwatch.elapsedMicroseconds / 1000;
    final framesDuringFlood = _frameCount - framesBefore;

    // Frame timings arrive a frame or two late, so flush before reading them.
    // The max below therefore covers the burst plus that short tail.
    await _idle(10);
    final worstUi = _collected.isEmpty
        ? 0.0
        : _collected
            .map((t) => t.buildDuration.inMicroseconds / 1000)
            .reduce((a, b) => a > b ? a : b);

    _report('flood: ${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB in '
        '${elapsedMs.toStringAsFixed(0)}ms '
        '(${(bytes / 1024 / elapsedMs).toStringAsFixed(1)} MiB/s)');
    _report('flood: $framesDuringFlood frames rendered during the write burst '
        '(${(framesDuringFlood * 1000 / elapsedMs).toStringAsFixed(1)} fps), '
        'worst UI frame ${worstUi.toStringAsFixed(1)}ms (burst + flush)');
    _report('flood: fps far below 60 here means output starves the frame '
        'pipeline - the unbounded-parse-per-write problem, not the paint path');
    _report('');

    setState(() => _status = 'done - see console');
  }

  Future<void> _runWorkload(
    String name,
    List<String> frames, {
    bool enterAltScreen = false,
  }) async {
    setState(() => _status = 'running $name');

    // Reset scrollback and attributes so each workload starts from the same
    // terminal state regardless of what ran before it.
    _terminal.write('\x1b[0m\x1b[2J\x1b[3J\x1b[H');
    if (enterAltScreen) _terminal.write('\x1b[?1049h');
    await _idle(5);

    for (var i = 0; i < _warmupFrames; i++) {
      _terminal.write(frames[i]);
      await SchedulerBinding.instance.endOfFrame;
    }

    await _idle(5);
    _collected.clear();

    for (var i = _warmupFrames; i < frames.length; i++) {
      _terminal.write(frames[i]);
      await SchedulerBinding.instance.endOfFrame;
    }

    await _idle(10);
    _results.add(_Result(name, List.of(_collected)));
    _collected.clear();

    if (enterAltScreen) _terminal.write('\x1b[?1049l');
    await _idle(5);
  }

  Future<void> _idle(int frames) async {
    for (var i = 0; i < frames; i++) {
      // endOfFrame only completes once a frame is actually scheduled, so nudge
      // the pipeline first - between workloads the terminal is quiet and
      // nothing else would schedule one.
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  void _printReport() {
    _report('');
    _report('workload    frames | UI p50  p90  p99 | RASTER p50  p90  p99 | '
        'over ${_frameBudgetMs.toStringAsFixed(1)}ms');
    for (final result in _results) {
      _report(result.format());
    }
    _report('');
    setState(() => _status = 'done - see console');
  }

  void _report(String line) {
    // ignore: avoid_print
    print('[xterm2-bench] $line');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _status,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          Center(
            child: SizedBox.fromSize(
              size: _viewportSize,
              child: TerminalView(
                _terminal,
                controller: _controller,
                padding: EdgeInsets.zero,
                // Keep every other option at its default: the benchmark should
                // measure the same code path a real embedder gets.
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Result {
  _Result(this.name, this.timings);

  final String name;
  final List<FrameTiming> timings;

  String format() {
    final ui = timings
        .map((t) => t.buildDuration.inMicroseconds / 1000)
        .toList(growable: false)
      ..sort();
    final raster = timings
        .map((t) => t.rasterDuration.inMicroseconds / 1000)
        .toList(growable: false)
      ..sort();

    if (ui.isEmpty) return '${name.padRight(11)}      0 | no frames captured';

    final over = timings
        .where((t) =>
            t.buildDuration.inMicroseconds / 1000 > _frameBudgetMs ||
            t.rasterDuration.inMicroseconds / 1000 > _frameBudgetMs)
        .length;

    return '${name.padRight(11)} ${ui.length.toString().padLeft(5)} | '
        '${_p(ui, 50)} ${_p(ui, 90)} ${_p(ui, 99)} | '
        '       ${_p(raster, 50)} ${_p(raster, 90)} ${_p(raster, 99)} | '
        '${(over * 100 / ui.length).toStringAsFixed(1)}%';
  }

  static String _p(List<double> sorted, int percentile) {
    final index = ((sorted.length - 1) * percentile / 100).round();
    return sorted[index].toStringAsFixed(1).padLeft(5);
  }
}

/// Plain scrolling ASCII. The cache-friendly path: a small set of distinct
/// glyphs, every one of them a paragraph cache hit after warm-up.
List<String> _plainFrames(int count) {
  return List.generate(count, (frame) {
    final buffer = StringBuffer();
    for (var row = 0; row < 3; row++) {
      final n = frame * 3 + row;
      buffer.write('[$n] /usr/local/lib/package_${n % 97}/'
          'source_file_${n % 31}.dart '
          '${n % 7 == 0 ? "WARN" : "ok"} ${n * 7919 % 100000}\r\n');
    }
    return buffer.toString();
  }, growable: false);
}

/// Scrolling text with heavy SGR churn. Same glyphs as `plain`, but many more
/// distinct colors, so the paragraph cache key space is much larger.
List<String> _sgrFrames(int count) {
  return List.generate(count, (frame) {
    final buffer = StringBuffer();
    for (var row = 0; row < 3; row++) {
      final n = frame * 3 + row;
      for (var segment = 0; segment < 8; segment++) {
        buffer.write('\x1b[38;5;${(n * 13 + segment * 31) % 256}m');
        buffer.write('segment$segment ');
      }
      buffer.write('\x1b[0m\r\n');
    }
    return buffer.toString();
  }, growable: false);
}

const _boxGlyphs = '─│┌┐└┘├┤┼█▓▒░▄▀';

/// Box drawing and block elements. These go through the procedural glyph
/// painter, which rebuilds paths every frame and never touches the paragraph
/// cache - the path a TUI with borders and meters spends most of its time in.
List<String> _boxFrames(int count) {
  return List.generate(count, (frame) {
    final buffer = StringBuffer();
    for (var row = 0; row < 3; row++) {
      final n = frame * 3 + row;
      buffer.write('\x1b[38;5;${(n * 7) % 256}m');
      for (var column = 0; column < 60; column++) {
        buffer.write(_boxGlyphs[(n + column) % _boxGlyphs.length]);
      }
      buffer.write('\x1b[0m\r\n');
    }
    return buffer.toString();
  }, growable: false);
}

/// One PTY-sized chunk of ordinary program output, ~8 KiB.
String _floodChunk() {
  final buffer = StringBuffer();
  var line = 0;
  while (buffer.length < 8192) {
    buffer.write('-rw-r--r--  1 user  staff  ${line * 7919 % 1000000} '
        'Aug  2 12:${(line % 60).toString().padLeft(2, '0')} '
        'file_${line}_with_a_reasonably_long_name.dart\r\n');
    line++;
  }
  return buffer.toString();
}

/// Cursor-addressed full-screen redraw on the alternate screen: every cell is
/// rewritten every frame, with a moving bar and per-row colors. This is the
/// deterministic stand-in for htop, without htop's run-to-run variance.
List<String> _fullscreenFrames(int count, int rows, int columns) {
  return List.generate(count, (frame) {
    final buffer = StringBuffer();
    for (var row = 0; row < rows; row++) {
      buffer.write('\x1b[${row + 1};1H');
      buffer.write('\x1b[48;5;${(row * 3 + frame) % 256}m'
          '\x1b[38;5;${(row * 11 + frame) % 256}m');
      final bar = (frame + row) % columns;
      for (var column = 0; column < columns; column++) {
        buffer.write(column < bar ? '█' : ' ');
      }
      buffer.write('\x1b[0m');
    }
    return buffer.toString();
  }, growable: false);
}
