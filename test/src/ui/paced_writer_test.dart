import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

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
    // The smallest positive budget, so a pass writes as little as the clock's
    // resolution allows. How little exactly is not deterministic - the test
    // asserts that the work was split across frames and arrived in order, not
    // where the splits fell.
    final writer = PacedTerminalWriter(
      terminal,
      frameBudget: const Duration(microseconds: 1),
      waitForFrame: waitForFrame,
    );

    const chunkCount = 200;
    for (var i = 0; i < chunkCount; i++) {
      writer.write('x');
    }
    await Future<void>.delayed(Duration.zero);

    expect(writer.hasPendingOutput, isTrue,
        reason: 'a 1us budget should not have taken all $chunkCount chunks');

    var pumps = 0;
    while (writer.hasPendingOutput) {
      await pumpFrame();
      pumps++;
      expect(pumps, lessThan(chunkCount + 10),
          reason: 'drain made no progress');
    }

    expect(terminal.buffer.lines[0].getText().trimRight(), 'x' * 20);
    expect(frames, isEmpty);
  });

  test('flush writes pending output immediately', () async {
    final terminal = Terminal()..resize(400, 5);
    final writer = PacedTerminalWriter(
      terminal,
      frameBudget: const Duration(microseconds: 1),
      waitForFrame: waitForFrame,
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
      frameBudget: const Duration(microseconds: 1),
      waitForFrame: waitForFrame,
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

  test('rejects a non-positive frame budget', () {
    expect(
      () => PacedTerminalWriter(Terminal(), frameBudget: Duration.zero),
      throwsArgumentError,
    );
  });
}
