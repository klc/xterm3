// Replays a recording into a headless terminal and prints the screen as text.
//
//   dart run script/screenshots/preview.dart example/assets/screenshots/vim.raw
//
// Used to check a recording caught what it was meant to before spending a
// Flutter run on rendering it.

import 'dart:convert';
import 'dart:io';

import 'package:xterm3/core.dart';

void main(List<String> args) {
  final terminal = Terminal(maxLines: 10000)..resize(100, 30);
  terminal.write(utf8.decode(File(args.first).readAsBytesSync(), allowMalformed: true));

  final buffer = terminal.buffer;
  final top = buffer.height - terminal.viewHeight;
  for (var row = top; row < buffer.height; row++) {
    stdout.writeln('|${buffer.lines[row].getText().trimRight()}');
  }
}
