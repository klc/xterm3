// Renders the README screenshots and writes them to `media/`.
//
//   cd example
//   flutter run --release -d macos -t lib/screenshot.dart
//
// Each scene replays a recording made by `script/screenshots/record.py` into a
// real `Terminal`, paints one frame of a real `TerminalView`, and captures the
// result through a `RepaintBoundary`. No PTY and no keystroke injection at
// capture time, so a re-run produces the same images from the same recordings.
//
// The grid is pinned to the size the recordings were made at. A terminal
// replaying 100-column output into a 92-column view would show wrapping the
// program never emitted.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm3/xterm.dart';

const _columns = 100;
const _rows = 30;

/// Written into the images. 2 is what a Retina screenshot would give; the
/// README displays them at 200px wide and links the full size.
const _pixelRatio = 2.0;

const _style = TerminalStyle(
  fontSize: 13,
  height: 1.2,
  fontFamily: 'Cascadia Mono',
);

void main() {
  runApp(const ScreenshotApp());
}

/// One image: a recording, the file it lands in, and anything to do to the
/// terminal once the recording has been replayed.
class Scene {
  const Scene({
    required this.recording,
    required this.output,
    this.decorate,
  });

  final String recording;
  final String output;
  final void Function(Terminal, TerminalController)? decorate;
}

final _scenes = <Scene>[
  const Scene(recording: 'shell', output: 'demo-shell.png'),
  const Scene(recording: 'htop', output: 'demo-htop.png'),
  const Scene(recording: 'vim', output: 'demo-vim.png'),
  Scene(
    recording: 'shell',
    output: 'demo-search.png',
    // The search overlay is xterm3's, not the recorded program's: the matches
    // are found in the buffer after the fact and handed to the controller,
    // which is exactly what an embedder's find bar does.
    decorate: (terminal, controller) {
      final matches = terminal.search('line');
      controller.setSearchHighlights(
        terminal.buffer,
        matches.map((match) => match.range).toList(),
        currentIndex: matches.length > 2 ? 2 : 0,
      );
    },
  ),
];

class ScreenshotApp extends StatefulWidget {
  const ScreenshotApp({super.key});

  @override
  State<ScreenshotApp> createState() => _ScreenshotAppState();
}

class _ScreenshotAppState extends State<ScreenshotApp> {
  final _boundary = GlobalKey();

  var _index = 0;
  Terminal? _terminal;
  TerminalController? _controller;
  var _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_index >= _scenes.length) {
      setState(() => _done = true);
      stdout.writeln('[xterm3-shot] done');
      exit(0);
    }

    final scene = _scenes[_index];
    final bytes = await rootBundle
        .load('assets/screenshots/${scene.recording}.raw')
        .then((data) => data.buffer.asUint8List());

    final terminal = Terminal(maxLines: 2000)..resize(_columns, _rows);
    final controller = TerminalController();
    // The recordings are UTF-8, and a program cut mid-sequence by the
    // recorder's deadline can leave a truncated one at the end.
    terminal.write(const Utf8Decoder(allowMalformed: true).convert(bytes));
    scene.decorate?.call(terminal, controller);

    setState(() {
      _terminal = terminal;
      _controller = controller;
    });

    // Two frames: one to build the view at the new size, one to let the
    // painter's glyph and paragraph caches fill so nothing is captured
    // mid-layout.
    await WidgetsBinding.instance.endOfFrame;
    await WidgetsBinding.instance.endOfFrame;
    await _capture(scene.output);

    _index++;
    await _load();
  }

  Future<void> _capture(String name) async {
    final boundary =
        _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: _pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    // The app runs from `example/`, and the images belong to the package.
    final file = File('../media/$name');
    file.writeAsBytesSync(data!.buffer.asUint8List());
    stdout.writeln('[xterm3-shot] $name  ${data.lengthInBytes} bytes');
  }

  @override
  Widget build(BuildContext context) {
    final terminal = _terminal;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        body: Center(
          child: _done || terminal == null
              ? const SizedBox.shrink()
              : RepaintBoundary(
                  key: _boundary,
                  child: _SizedTerminal(
                    terminal: terminal,
                    controller: _controller!,
                  ),
                ),
        ),
      ),
    );
  }
}

/// The advance width and line height of one cell in [style].
///
/// The renderer derives this the same way, from a run of a reference glyph;
/// there is no constant to read, because it comes out of the font at the
/// current text scale.
Size _cellSize(TerminalStyle style) {
  const reference = 'mmmmmmmmmm';

  final textStyle = style.toTextStyle();
  final builder = ui.ParagraphBuilder(textStyle.getParagraphStyle())
    ..pushStyle(textStyle.getTextStyle(textScaler: TextScaler.noScaling))
    ..addText(reference);

  final paragraph = builder.build()
    ..layout(const ui.ParagraphConstraints(width: double.infinity));
  final size = Size(
    paragraph.maxIntrinsicWidth / reference.length,
    paragraph.height,
  );
  paragraph.dispose();
  return size;
}

/// Sizes the view to exactly [_columns] x [_rows] cells.
///
/// The cell size is not a constant anyone can write down - it comes out of the
/// font at the current text scale - so it is measured through the same
/// `CharMetrics` the renderer uses rather than guessed at.
class _SizedTerminal extends StatelessWidget {
  const _SizedTerminal({required this.terminal, required this.controller});

  final Terminal terminal;
  final TerminalController controller;

  @override
  Widget build(BuildContext context) {
    final cell = _cellSize(_style);
    const padding = 12.0;

    return Container(
      color: TerminalThemes.defaultTheme.background,
      padding: const EdgeInsets.all(padding),
      child: SizedBox(
        width: cell.width * _columns,
        height: cell.height * _rows,
        child: TerminalView(
          terminal,
          controller: controller,
          textStyle: _style,
          autoResize: false,
          padding: EdgeInsets.zero,
          alwaysShowCursor: true,
          readOnly: true,
        ),
      ),
    );
  }
}
