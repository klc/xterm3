import 'dart:async';
import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:xterm3/src/terminal.dart';

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
/// The budget is per frame, not per [write] call: a PTY stream delivers one
/// chunk per event-loop turn, so time spent in [Terminal.write] adds up
/// across calls, and once [frameBudget] of it is spent since the last frame,
/// further output is only queued until the next frame. A chunk that arrives
/// after the writer has been idle for a frame interval is written at once.
///
/// If no frame comes - the window is minimised or hidden, where the scheduler
/// stops producing frames - the writer does not wait for one indefinitely.
/// After 100ms without a frame it stops waiting for one: until a frame comes
/// again, each spent budget waits only a frame interval, so output keeps
/// draining and replies the terminal owes the application still go out.
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
    Stopwatch Function()? createStopwatch,
  })  : _waitForFrame = waitForFrame ?? _endOfFrame,
        _createStopwatch = createStopwatch ?? Stopwatch.new {
    if (frameBudget <= Duration.zero) {
      throw ArgumentError.value(frameBudget, 'frameBudget', 'must be positive');
    }
  }

  final Terminal terminal;

  /// How long the writer may spend inside [Terminal.write] per frame, summed
  /// across [write] calls, before holding further output until a frame has
  /// been produced.
  ///
  /// Measured against a 16.7ms frame: 8ms leaves room for the paint the write
  /// just dirtied. Going lower does not buy more frames - 4ms measured the
  /// same frame rate as 8ms and only drained more slowly - so treat this as a
  /// ceiling on stutter, not a tuning knob.
  final Duration frameBudget;

  /// Injectable so this can be tested without a running frame pipeline.
  final Future<void> Function() _waitForFrame;

  /// Injectable so pass sizes can be tested deterministically instead of
  /// racing wall-clock resolution.
  final Stopwatch Function() _createStopwatch;

  /// A frame at 60Hz. A writer idle this long is treated as having seen a
  /// frame it did not ask for: its last write dirtied the view, which
  /// scheduled one, and nothing has held the UI thread since.
  static const _frameInterval = Duration(milliseconds: 17);

  /// How long a spent budget waits for a frame before concluding frames have
  /// stopped. Well above the frame gaps of a paced burst, so it only fires
  /// when they have. Until the frame asked for arrives, later spent budgets
  /// wait [_frameInterval] instead of this long again.
  static const _frameTimeout = Duration(milliseconds: 100);

  final _pending = Queue<String>();

  /// Time spent inside [Terminal.write] in the current budget window.
  Stopwatch? _spent;

  /// Wall time since the last write.
  late final _idle = _createStopwatch()..start();

  /// Non-null while a spent budget waits for a frame; fires when none comes.
  Timer? _frameWait;

  /// A [_waitForFrame] future is unresolved. Not asked again until it
  /// resolves, so a writer whose frames have stopped holds one listener on
  /// it, not one per timeout.
  var _frameRequested = false;

  var _scheduled = false;

  var _disposed = false;

  /// Whether output is waiting to be parsed.
  bool get hasPendingOutput => _pending.isNotEmpty;

  /// Number of chunks waiting to be parsed.
  int get pendingChunks => _pending.length;

  /// Queues [data] to be written to the terminal.
  ///
  /// Returns immediately - genuinely so, unlike calling [_drain] inline
  /// would: starting the drain on a microtask instead lets a burst of
  /// synchronous write() calls (a tight producer loop, or a sync
  /// StreamController delivering several chunks in one native callback) all
  /// land in the queue before the first pass looks at it, instead of each
  /// call racing its own one-chunk drain to completion.
  ///
  /// Everything goes through the queue, so a chunk can never overtake output
  /// that is waiting for a frame.
  void write(String data) {
    if (_disposed || data.isEmpty) return;
    _pending.addLast(data);
    if (!_scheduled && _frameWait == null) {
      _scheduled = true;
      scheduleMicrotask(_drain);
    }
  }

  /// Writes everything queued, without pacing.
  ///
  /// For the cases where latency matters more than smoothness - a prompt that
  /// has to appear now, or a teardown that has to leave nothing unparsed.
  void flush() {
    _frameWait?.cancel();
    _frameWait = null;
    while (_pending.isNotEmpty) {
      if (_disposed) return;
      terminal.write(_pending.removeFirst());
    }
  }

  /// Drops anything not yet written and stops draining.
  void dispose() {
    _disposed = true;
    _pending.clear();
    _frameWait?.cancel();
    _frameWait = null;
  }

  void _drain() {
    _scheduled = false;
    if (_frameWait != null) return;

    // The writer only learns about frames it waits for. Frames it did not
    // ask for are inferred from idleness instead: a frame interval without a
    // write has seen one, so a chunk arriving after idle starts a fresh
    // budget - even if the last burst spent the old one exactly - and is
    // written at once. Checked before the spent test so that holds. Idle
    // since the last write, not since the budget started: a steady stream
    // with short gaps is still one burst and must still wait for a frame.
    if (_spent != null && _idle.elapsed >= _frameInterval) _spent = null;

    while (_pending.isNotEmpty) {
      final spent = _spent;
      if (spent == null) {
        _spent = _createStopwatch();
      } else if (spent.elapsed >= frameBudget) {
        // Checked before writing, never after: with a PTY stream the next
        // chunk arrives on a later turn, and that is the one that must wait.
        // The first chunk of a window is written unchecked, so drain still
        // makes progress when frameBudget is close to clock resolution.
        return _waitForNextFrame();
      }
      final window = _spent!..start();
      terminal.write(_pending.removeFirst());
      window.stop();
      _idle.reset();
      if (_disposed) return;
    }
  }

  void _waitForNextFrame() {
    // Still unresolved: a timeout has passed without the frame, so don't wait
    // for it again. Still leave a frame interval between budgets rather than
    // one event-loop turn: if the window is in fact visible and only a frame
    // was slow, back-to-back budgets starve the frames - measured, a
    // zero-delay yield let them stall for over a second, as unpaced output
    // does.
    if (_frameRequested) {
      _frameWait = Timer(_frameInterval, _nextWindow);
      return;
    }
    _frameWait = Timer(_frameTimeout, _nextWindow);
    _frameRequested = true;
    unawaited(_waitForFrame().then((_) {
      _frameRequested = false;
      _nextWindow();
    }));
  }

  /// A frame has been produced, or [_frameTimeout] passed without one.
  void _nextWindow() {
    if (_disposed) return;
    _frameWait?.cancel();
    _frameWait = null;
    _spent = null;
    _drain();
  }
}

Future<void> _endOfFrame() => SchedulerBinding.instance.endOfFrame;
