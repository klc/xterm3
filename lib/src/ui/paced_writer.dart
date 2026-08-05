import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:xterm2/src/terminal.dart';

/// Writes PTY output into a [Terminal] a frame's worth at a time, so a burst
/// of output cannot hold the UI thread for longer than [frameBudget].
///
/// Handing every chunk straight to [Terminal.write] as it arrives parses the
/// whole burst at whatever rate the machine manages, and frames happen in the
/// gaps. On a 170x50 grid, 32 MiB of `cat`-style output measured 566ms to
/// drain and 37 frames per second while it did. The same burst through this
/// writer with the default budget measured 854ms and 75 frames per second -
/// the display's full refresh rate.
///
/// So this is a trade, not a free win: **output drains around 50% slower and
/// the terminal stays smooth while it does.** Which one is right depends on
/// the application. Nothing in the package uses this by default.
///
/// ```dart
/// final writer = PacedTerminalWriter(terminal);
/// pty.output.map(utf8.decode).listen(writer.write);
/// // ...
/// writer.dispose();
/// ```
///
/// Ordering is preserved: chunks are parsed in the order they were written,
/// and nothing is dropped. There is no back pressure - pending chunks are held
/// until they can be parsed, exactly as the PTY stream's own buffer would hold
/// them.
class PacedTerminalWriter {
  PacedTerminalWriter(
    this.terminal, {
    this.frameBudget = const Duration(milliseconds: 8),
    Future<void> Function()? waitForFrame,
  })  : _waitForFrame = waitForFrame ?? _endOfFrame {
    if (frameBudget <= Duration.zero) {
      throw ArgumentError.value(frameBudget, 'frameBudget', 'must be positive');
    }
  }

  final Terminal terminal;

  /// How long a single drain pass may spend inside [Terminal.write] before
  /// yielding to let a frame be produced.
  ///
  /// Measured against a 16.7ms frame: 8ms leaves room for the paint the write
  /// just dirtied. Going lower does not buy more frames - 4ms measured the
  /// same frame rate as 8ms and only drained more slowly - so treat this as a
  /// ceiling on stutter, not a tuning knob.
  final Duration frameBudget;

  /// Injectable so this can be tested without a running frame pipeline.
  final Future<void> Function() _waitForFrame;

  final _pending = Queue<String>();

  var _draining = false;

  var _disposed = false;

  /// Whether output is waiting to be parsed.
  bool get hasPendingOutput => _pending.isNotEmpty;

  /// Number of chunks waiting to be parsed.
  int get pendingChunks => _pending.length;

  /// Queues [data] to be written to the terminal.
  ///
  /// Returns immediately. The data reaches the terminal within the next few
  /// frames, sooner if there is little of it.
  void write(String data) {
    if (_disposed || data.isEmpty) return;
    _pending.addLast(data);
    if (!_draining) {
      _draining = true;
      unawaited(_drain());
    }
  }

  /// Writes everything queued, without pacing.
  ///
  /// For the cases where latency matters more than smoothness - a prompt that
  /// has to appear now, or a teardown that has to leave nothing unparsed.
  void flush() {
    while (_pending.isNotEmpty) {
      if (_disposed) return;
      terminal.write(_pending.removeFirst());
    }
  }

  /// Drops anything not yet written and stops draining.
  void dispose() {
    _disposed = true;
    _pending.clear();
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        if (_disposed) return;

        final slice = Stopwatch()..start();
        while (_pending.isNotEmpty &&
            slice.elapsed < frameBudget &&
            !_disposed) {
          terminal.write(_pending.removeFirst());
        }

        if (_pending.isEmpty || _disposed) return;
        await _waitForFrame();
      }
    } finally {
      _draining = false;
    }
  }
}

Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame;
