import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm3/xterm.dart';

/// Deterministic stand-in for [Stopwatch]: reports zero elapsed for the
/// first [chunksPerPass] reads of `elapsed`, then reports far past any
/// budget. Makes pass sizes an exact chunk count instead of a race against
/// wall-clock resolution (see Bulgu 2 in CODE_REVIEW_2026-08-06.md).
class _SteppedStopwatch implements Stopwatch {
  _SteppedStopwatch(this.chunksPerPass);

  final int chunksPerPass;
  var _reads = 0;

  @override
  void start() {}
  @override
  void stop() {}
  @override
  void reset() {}
  @override
  bool get isRunning => true;
  @override
  int get elapsedTicks => elapsed.inMicroseconds;
  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
  @override
  int get frequency => 1000000;
  @override
  Duration get elapsed {
    _reads++;
    return _reads > chunksPerPass ? const Duration(seconds: 1) : Duration.zero;
  }
}

/// Wall clock owned by the test. Time moves only when a write runs (see
/// [_TimedTerminal]) or when the test advances [now] itself - so "the budget
/// is spent" and "a frame interval has passed" can be set independently,
/// which [_SteppedStopwatch] cannot express.
class _Clock {
  var now = Duration.zero;
}

/// [Stopwatch] over a [_Clock], honouring start/stop like the real one.
class _ClockStopwatch implements Stopwatch {
  _ClockStopwatch(this.clock);

  final _Clock clock;
  var _accumulated = Duration.zero;
  Duration? _startedAt;

  @override
  void start() => _startedAt ??= clock.now;
  @override
  void stop() {
    if (_startedAt == null) return;
    _accumulated += clock.now - _startedAt!;
    _startedAt = null;
  }

  @override
  void reset() {
    _accumulated = Duration.zero;
    if (_startedAt != null) _startedAt = clock.now;
  }

  @override
  bool get isRunning => _startedAt != null;
  @override
  int get elapsedTicks => elapsed.inMicroseconds;
  @override
  int get elapsedMicroseconds => elapsed.inMicroseconds;
  @override
  int get elapsedMilliseconds => elapsed.inMilliseconds;
  @override
  int get frequency => 1000000;
  @override
  Duration get elapsed =>
      _accumulated +
      (_startedAt == null ? Duration.zero : clock.now - _startedAt!);
}

/// A terminal where every write takes [writeCost] on [clock].
class _TimedTerminal extends Terminal {
  _TimedTerminal(this.clock, this.writeCost);

  final _Clock clock;
  final Duration writeCost;

  @override
  void write(String data) {
    super.write(data);
    clock.now += writeCost;
  }
}

/// A terminal that calls [onWrite] after every write.
class _HookTerminal extends Terminal {
  void Function()? onWrite;

  @override
  void write(String data) {
    super.write(data);
    onWrite?.call();
  }
}

void main() {
  /// Drives the writer without a frame pipeline: every yield completes only
  /// when the test says so, which is what makes the pacing observable.
  late List<Completer<void>> frames;
  Future<void> waitForFrame() {
    final completer = Completer<void>();
    frames.add(completer);
    return completer.future;
  }

  Future<void> pumpFrame() async {
    expect(frames, isNotEmpty, reason: 'writer is not waiting for a frame');
    frames.removeAt(0).complete();
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() => frames = []);

  test('writes everything in order', () async {
    final terminal = Terminal()..resize(20, 5);
    final writer = PacedTerminalWriter(
      terminal,
      // Large enough that one pass takes it all, so this test is about
      // ordering rather than pacing.
      frameBudget: const Duration(seconds: 10),
      waitForFrame: waitForFrame,
    );

    writer.write('one ');
    writer.write('two ');
    writer.write('three');
    await Future<void>.delayed(Duration.zero);

    expect(terminal.buffer.lines[0].getText().trimRight(), 'one two three');
    expect(writer.hasPendingOutput, isFalse);
    expect(frames, isEmpty, reason: 'nothing needed to be deferred');
  });

  test('defers output past the budget to later frames', () async {
    final terminal = Terminal()..resize(20, 5);
    // Fake clock instead of a real 1us budget: a wall-clock budget that
    // close to Stopwatch resolution made pass sizes - and therefore whether
    // this test passed at all - a hardware lottery. 10 chunks/pass is now
    // exact, so the frame count below is an equality, not a bound.
    final writer = PacedTerminalWriter(
      terminal,
      frameBudget: const Duration(milliseconds: 8),
      waitForFrame: waitForFrame,
      createStopwatch: () => _SteppedStopwatch(9),
    );

    const chunkCount = 200;
    for (var i = 0; i < chunkCount; i++) {
      writer.write('x');
    }
    await Future<void>.delayed(Duration.zero);

    expect(writer.hasPendingOutput, isTrue,
        reason: 'first pass should have written only 10 of $chunkCount chunks');

    var pumps = 0;
    while (writer.hasPendingOutput) {
      await pumpFrame();
      pumps++;
    }
    expect(pumps, equals(19), reason: '190 remaining chunks at 10/pass');

    expect(terminal.buffer.lines[0].getText().trimRight(), 'x' * 20);
    expect(frames, isEmpty);
  });

  test('flush writes pending output immediately', () async {
    final terminal = Terminal()..resize(400, 5);
    final writer = PacedTerminalWriter(
      terminal,
      frameBudget: const Duration(milliseconds: 8),
      waitForFrame: waitForFrame,
      createStopwatch: () => _SteppedStopwatch(9),
    );

    for (var i = 0; i < 200; i++) {
      writer.write('x');
    }
    await Future<void>.delayed(Duration.zero);
    expect(writer.hasPendingOutput, isTrue);

    writer.flush();

    expect(terminal.buffer.lines[0].getText().trimRight(), 'x' * 200);
    expect(writer.hasPendingOutput, isFalse);
  });

  test('dispose drops pending output', () async {
    final terminal = Terminal()..resize(200, 5);
    final writer = PacedTerminalWriter(
      terminal,
      frameBudget: const Duration(milliseconds: 8),
      waitForFrame: waitForFrame,
      createStopwatch: () => _SteppedStopwatch(9),
    );

    for (var i = 0; i < 200; i++) {
      writer.write('x');
    }
    await Future<void>.delayed(Duration.zero);
    final writtenBeforeDispose =
        terminal.buffer.lines[0].getText().trimRight().length;
    expect(writer.hasPendingOutput, isTrue);

    writer.dispose();
    while (frames.isNotEmpty) {
      await pumpFrame();
    }

    expect(writer.hasPendingOutput, isFalse);
    expect(terminal.buffer.lines[0].getText().trimRight().length,
        writtenBeforeDispose,
        reason: 'nothing queued at disposal should reach the terminal');

    // Writes after disposal are ignored rather than throwing.
    writer.write('y');
    await Future<void>.delayed(Duration.zero);
    expect(terminal.buffer.lines[0].getText(), isNot(contains('y')));
  });

  // A PTY stream delivers one chunk per event-loop turn. Each write below
  // costs 3ms against the default 8ms budget, so three chunks spend it.
  group('budget per frame across event-loop turns', () {
    late _Clock clock;
    late _TimedTerminal terminal;
    late PacedTerminalWriter writer;
    String text() => terminal.buffer.lines[0].getText().trimRight();

    PacedTerminalWriter newWriter() => PacedTerminalWriter(
          terminal,
          waitForFrame: waitForFrame,
          createStopwatch: () => _ClockStopwatch(clock),
        );

    setUp(() {
      clock = _Clock();
      terminal = _TimedTerminal(clock, const Duration(milliseconds: 3))
        ..resize(40, 5);
      writer = newWriter();
    });

    Future<void> writeTurn(String data) async {
      writer.write(data);
      await Future<void>.delayed(Duration.zero);
    }

    test('one chunk per turn waits for a frame once the budget is spent',
        () async {
      for (final c in 'abcdefghij'.split('')) {
        await writeTurn(c);
      }

      expect(text(), 'abc', reason: 'the 4th chunk found the budget spent');
      expect(writer.pendingChunks, 7);
      expect(frames, hasLength(1), reason: 'one frame wait for the burst');

      var pumps = 0;
      while (writer.hasPendingOutput) {
        await pumpFrame();
        pumps++;
      }
      expect(pumps, 3, reason: '7 queued chunks at 3 per frame');
      expect(text(), 'abcdefghij');
      expect(frames, isEmpty);
    });

    test('a steady stream with short gaps still waits for a frame', () async {
      // 5ms between chunks: never idle for a frame interval, so the budget
      // keeps adding up however much wall time the stream spans.
      for (final c in 'abcd'.split('')) {
        await writeTurn(c);
        clock.now += const Duration(milliseconds: 5);
      }

      expect(text(), 'abc');
      expect(writer.pendingChunks, 1);
      expect(frames, hasLength(1));

      await pumpFrame();
      expect(text(), 'abcd');
    });

    test('a single chunk after idle is written at once', () async {
      await writeTurn('a');
      expect(text(), 'a');
      expect(frames, isEmpty);
    });

    test(
        'a chunk after a frame interval of idle is written at once, '
        'even when the earlier burst spent the whole budget', () async {
      // Spends the budget exactly, with nothing left queued: no frame wait
      // is needed, but the window is spent.
      writer.write('a');
      writer.write('b');
      writer.write('c');
      await Future<void>.delayed(Duration.zero);
      expect(text(), 'abc');
      expect(frames, isEmpty);

      // Frames happen without the writer asking; it only sees time pass.
      clock.now += const Duration(milliseconds: 20);
      await writeTurn('d');
      await writeTurn('e');
      await writeTurn('f');

      expect(text(), 'abcdef', reason: 'a fresh budget, not the spent one');
      expect(frames, isEmpty, reason: 'nothing waited for a frame');
    });

    test('a chunk arriving behind queued chunks does not overtake them',
        () async {
      for (final c in 'abcd'.split('')) {
        await writeTurn(c);
      }
      expect(text(), 'abc');
      expect(writer.pendingChunks, 1);

      // Long enough that an idle writer would start a fresh budget - but
      // the writer is not idle, 'd' is still queued.
      clock.now += const Duration(milliseconds: 50);
      await writeTurn('e');
      expect(text(), 'abc');
      expect(writer.pendingChunks, 2);

      await pumpFrame();
      expect(text(), 'abcde');
      expect(writer.hasPendingOutput, isFalse);
    });

    testWidgets('dispose while waiting writes nothing and leaves no timer',
        (tester) async {
      for (final c in 'abcd'.split('')) {
        writer.write(c);
        await tester.pump();
      }
      expect(text(), 'abc');
      expect(writer.pendingChunks, 1, reason: 'waiting on a frame');

      writer.dispose();
      while (frames.isNotEmpty) {
        frames.removeAt(0).complete();
      }
      await tester.pump();
      writer.write('e');
      await tester.pump();

      expect(text(), 'abc');
      expect(writer.hasPendingOutput, isFalse);
      // A timer still pending here fails the test when it ends.
    });
  });

  testWidgets('drains when the frame never comes', (tester) async {
    final terminal = Terminal()..resize(400, 5);
    final writer = PacedTerminalWriter(
      terminal,
      waitForFrame: () => Completer<void>().future,
      createStopwatch: () => _SteppedStopwatch(9),
    );

    for (var i = 0; i < 200; i++) {
      writer.write('x');
    }
    await tester.pump();
    expect(terminal.buffer.lines[0].getText().trimRight(), 'x' * 10);

    await tester.pump(const Duration(seconds: 5));

    expect(terminal.buffer.lines[0].getText().trimRight(), 'x' * 200);
    expect(writer.hasPendingOutput, isFalse);
    // A timer still pending here fails the test when it ends.
  });

  group('once frames have stopped', () {
    late _HookTerminal terminal;
    late PacedTerminalWriter writer;
    String text() => terminal.buffer.lines[0].getText().trimRight();
    String digits(int from, int to) =>
        [for (var i = from; i < to; i++) '${i % 10}'].join();
    void writeDigits(int from, int to) {
      for (var i = from; i < to; i++) {
        writer.write('${i % 10}');
      }
    }

    setUp(() {
      terminal = _HookTerminal()..resize(400, 5);
      writer = PacedTerminalWriter(
        terminal,
        waitForFrame: waitForFrame,
        createStopwatch: () => _SteppedStopwatch(9),
      );
    });

    testWidgets('only the first wait times out; the rest wait a frame interval',
        (tester) async {
      writeDigits(0, 200);
      await tester.pump();
      expect(text(), digits(0, 10));

      // One timeout tells the writer frames have stopped; each later budget
      // window waits 17ms instead of another 100ms.
      await tester.pump(const Duration(milliseconds: 100));
      expect(text(), digits(0, 20));
      await tester.pump(const Duration(milliseconds: 17));
      expect(text(), digits(0, 30));
      await tester.pump(const Duration(milliseconds: 17 * 17));

      expect(text(), digits(0, 200));
      expect(writer.hasPendingOutput, isFalse);
      expect(frames, hasLength(1), reason: 'still one unresolved request');
    });

    testWidgets('pacing comes back when the frame does', (tester) async {
      writeDigits(0, 30);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 17));
      expect(text(), digits(0, 30));

      // The frame that stopped coming arrives.
      frames.removeAt(0).complete();
      await tester.pump();

      writeDigits(30, 60);
      await tester.pump();
      expect(text(), digits(0, 40));
      expect(frames, hasLength(1), reason: 'waiting on a frame again');

      // Short of the timeout: no frame, no more output.
      await tester.pump(const Duration(milliseconds: 50));
      expect(text(), digits(0, 40));

      frames.removeAt(0).complete();
      await tester.pump();
      expect(text(), digits(0, 50));

      frames.removeAt(0).complete();
      await tester.pump();
      expect(text(), digits(0, 60));
    });

    testWidgets('dispose while draining without frames leaves no timer',
        (tester) async {
      writeDigits(0, 20);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(text(), digits(0, 20));

      // Frames have stopped, so this burst's next window is a frame interval
      // away, not a timeout; dispose part-way through it.
      terminal.onWrite = () {
        if (text().length == 25) writer.dispose();
      };
      writeDigits(20, 40);
      await tester.pump();
      expect(text(), digits(0, 20));
      await tester.pump(const Duration(milliseconds: 17));
      expect(text(), digits(0, 25));

      await tester.pump(const Duration(seconds: 1));

      expect(text(), digits(0, 25));
      expect(writer.hasPendingOutput, isFalse);
      // A timer still pending here fails the test when it ends.
    });
  });

  test('rejects a non-positive frame budget', () {
    expect(
      () => PacedTerminalWriter(Terminal(), frameBudget: Duration.zero),
      throwsArgumentError,
    );
  });
}
