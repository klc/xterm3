// The end-to-end path of example/lib/e2e_bench.dart without Flutter: flutter_pty2
// 3.x spawns `python3 drive.py ...` in a 100x37 PTY, its output goes through a
// chunked Utf8Decoder into a headless Terminal, and the Terminal's replies (the
// DSR answers that stop drive.py's clock) go back to the PTY. Comparing it with
// the app on the same plugin separates what Flutter's platform thread costs
// from what the plugin, the stream and the core cost.
//
//   dart build cli -o <out>          (from this directory; bundles the PTY dylib)
//   <out>/bundle/bin/cli_e2e <drive.py> <term> <results.jsonl> <payload>...
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:xterm3/src/terminal.dart';

class _Sink implements Sink<String> {
  _Sink(this.f);
  final void Function(String) f;
  @override
  void add(String s) => f(s);
  @override
  void close() {}
}

Future<void> main(List<String> args) async {
  final terminal = Terminal(maxLines: 10000)..resize(100, 37);
  final session = await Pty.spawn(PtySpawnOptions(
    executable: '/usr/bin/python3',
    arguments: args,
    size: const PtySize(columns: 100, rows: 37),
  ));
  final dec = const Utf8Decoder().startChunkedConversion(_Sink(terminal.write));
  session.output.listen(dec.add);
  terminal.onOutput = (d) => unawaited(session.input.writeUtf8(d));
  await session.done;
  exit(0);
}
