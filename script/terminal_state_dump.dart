// Digests everything a Terminal leaves behind and everything it emits while
// parsing a file, under several ways of cutting the file into writes, so two
// builds of the parser can be compared without trusting either.
//
//   dart compile exe script/terminal_state_dump.dart -o /tmp/tsd
//   /tmp/tsd [--chunkings=whole,1,2,3,7,64,1024,65536,r1,r2,r3]
//            [--debugger-limit=N] [--full] <files...>
//
// A file is decoded to one String up front (UTF-8 with malformed bytes
// replaced; a `.u16le` file is raw UTF-16LE, so it can hold lone surrogates)
// and then fed to a fresh 100x37 `Terminal(maxLines: 10000)`:
//
//   whole  one write
//   N      writes of N code units - they split surrogate pairs and sequences
//   rK     seeded random splits (seed K), mostly 1-16 units, some long ones,
//          the occasional empty write
//
// Every callback the Terminal exposes is attached and logs its name and
// arguments in order; the ones that answer return fixed values, so the reply
// paths run. Exceptions thrown by `write` are logged, not fatal. After the
// input the state is digested: for both buffers every line (scrollback
// included) with its wrap flag and every cell's content, fg, bg, attributes,
// hyperlink id, underline colour, semantic content and combining characters;
// cursors, margins, the cursor style, every mode with a getter, which buffer
// is active, colour overrides. Then a probe is written - a character, CPRs,
// DECRC, title reports and a title pop, tab stops walked with CPRs, DECRQM
// for common modes, DECRQSS - so state without a getter (pending wrap,
// charset, saved cursor, title stack, tab stops, SGR) shows up in the replies,
// and everything is digested again.
//
// The same input is also fed, up to --debugger-limit code units (default
// 262144), to `TerminalDebugger`: a bare EscapeParser whose handler is not an
// EscapeTextHandler, so every code point goes through the per-code-point path,
// and whose log records each handler call with its arguments.
//
// One line per (file, chunking):
//   <file> <chunking> state=<h> events=<h> unknown=<h> dbg=<h> notify=<n>
// `unknown` is onUnknownSequence alone: its text is cut to what the parser
// still retains, so it depends on how the input was split. `notify` counts
// listener notifications, one or more per write. `--full` also prints the
// dump and the logs behind the hashes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:xterm3/src/core/color_scheme.dart';
import 'package:xterm3/src/terminal.dart';
import 'package:xterm3/src/utils/debugger.dart';

const _defaultChunkings = [
  'whole', '1', '2', '3', '7', '64', '1024', '65536', 'r1', 'r2', 'r3', //
];

const _probeDecModes = [
  1, 3, 5, 6, 7, 12, 25, 45, 47, 66, 67, 69, 1000, 1002, 1003, 1004, 1005, //
  1006, 1015, 1016, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 9, 1007, 1036,
];

String _probe() {
  final b = StringBuffer('Zqxj`a\x1b[6n\x1b[?6n\x1b8\x1b[6n'
      '\x1b[21t\x1b[20t\x1b[23;0t\x1b[21t\x1b[20t\r');
  for (var i = 0; i < 14; i++) {
    b.write('\t\x1b[6n');
  }
  for (final m in _probeDecModes) {
    b.write('\x1b[?$m\$p');
  }
  for (final m in [2, 4, 12, 20]) {
    b.write('\x1b[$m\$p');
  }
  for (final q in ['m', 'r', 's', ' q', '"q', '"p']) {
    b.write('\x1bP\$q$q\x1b\\');
  }
  b.write('Y\x1b[6n');
  return b.toString();
}

Future<void> main(List<String> args) async {
  var chunkings = _defaultChunkings;
  var debuggerLimit = 262144;
  var full = false;
  final files = <String>[];
  for (final a in args) {
    if (a.startsWith('--chunkings=')) {
      chunkings = a.substring(12).split(',');
    } else if (a.startsWith('--debugger-limit=')) {
      debuggerLimit = int.parse(a.substring(17));
    } else if (a == '--full') {
      full = true;
    } else {
      files.add(a);
    }
  }

  final probe = _probe();
  for (final path in files) {
    final input = _read(path);
    final name = path.split('/').last;
    for (final chunking in chunkings) {
      final chunks = _split(input, chunking, name);
      final r = await _run(chunks, probe, full);
      final dbg = _runDebugger(input, chunking, name, debuggerLimit, full);
      stdout.writeln('$name $chunking state=${r.state} events=${r.events} '
          'unknown=${r.unknown} dbg=${dbg.hash} notify=${r.notify}');
      if (full) {
        stdout.write(r.dump);
        stdout.write(dbg.dump);
      }
    }
  }
  exit(0);
}

String _read(String path) {
  final bytes = File(path).readAsBytesSync();
  if (path.endsWith('.u16le')) {
    return String.fromCharCodes(
        Uint16List.sublistView(bytes, 0, bytes.length & ~1));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

List<String> _split(String input, String chunking, String name) {
  if (chunking == 'whole') return [input];
  final out = <String>[];
  if (chunking.startsWith('r')) {
    final random = Random(int.parse(chunking.substring(1)) * 7919 +
        name.codeUnits.fold(0, (h, u) => (h * 31 + u) & 0xfffffff));
    var i = 0;
    while (i < input.length) {
      final n = switch (random.nextInt(32)) {
        0 => 0,
        1 => random.nextInt(8192) + 1,
        _ => random.nextInt(16) + 1,
      };
      final end = min(i + n, input.length);
      out.add(input.substring(i, end));
      i = end;
    }
    return out;
  }
  final n = int.parse(chunking);
  for (var i = 0; i < input.length; i += n) {
    out.add(input.substring(i, min(i + n, input.length)));
  }
  return out;
}

class _Hash {
  var value = 0xcbf29ce484222325;
  void add(int v) => value = (value ^ v) * 0x100000001b3;
  void addString(String? s) {
    if (s == null) {
      add(-1);
      return;
    }
    add(s.length);
    for (var i = 0; i < s.length; i++) {
      add(s.codeUnitAt(i));
    }
  }

  @override
  String toString() => '${(value >>> 32).toRadixString(16).padLeft(8, '0')}'
      '${(value & 0xffffffff).toRadixString(16).padLeft(8, '0')}';
}

Future<
    ({
      String state,
      String events,
      String unknown,
      int notify,
      String dump,
    })> _run(List<String> chunks, String probe, bool full) async {
  final events = <String>[];
  final unknown = <String>[];
  void log(String e) => events.add(e);
  late final Terminal terminal;
  terminal = Terminal(
    maxLines: 10000,
    allowRemoteResize: true,
    onBell: () => log('bell'),
    onTitleChange: (t) => log('title $t'),
    onIconChange: (t) => log('icon $t'),
    onCurrentDirectoryChange: (u) => log('cwd $u'),
    onRemoteHostChange: (v) => log('remoteHost $v'),
    onUserVariableChange: (n, v) => log('userVar $n=$v'),
    onITerm2VariableQuery: (n) {
      log('it2VarQuery $n');
      return 'v-$n';
    },
    onITerm2BadgeFormatChange: (f) => log('it2Badge $f'),
    onITerm2ShellIntegrationVersionChange: (v) => log('it2ShellVer $v'),
    onITerm2Mark: () => log('it2Mark'),
    onITerm2ProfileChange: (p) => log('it2Profile $p'),
    onFocusRequest: () => log('focus'),
    onOpenUrl: (u) => log('openUrl $u'),
    onAttentionRequest: (v) => log('attention $v'),
    onNotification: (t, b) => log('notify $t|$b'),
    onMouseShapeChange: (s) => log('mouseShape $s'),
    onProgressReport: (p) => log('progress ${p.state} ${p.progress}'),
    onSemanticPrompt: (s) => log('semPrompt ${s.content} '
        '${s.lastCommandExitCode} ${s.aid} ${s.promptKind} ${s.clickMode} '
        '${s.redraw} ${s.specialKey} ${s.commandLine}'),
    onContextSignal: (s) =>
        log('context ${s.action} ${s.id} ${s.metadata.entries.toList()}'),
    onColorQuery: (code, index) {
      log('colorQuery $code $index');
      return (code * 7919 + (index ?? 0) * 31) & 0xffffff;
    },
    onColorSchemeQuery: () {
      log('colorSchemeQuery');
      return TerminalColorScheme.dark;
    },
    onXtVersionQuery: () {
      log('xtversion');
      return 'dump-1.0';
    },
    onEnquiry: () {
      log('enquiry');
      return 'enq-answer';
    },
    onClipboardStore: (s, t) => log('clipStore $s $t'),
    onClipboardQuery: (s) {
      log('clipQuery $s');
      return 'clip-$s';
    },
    onOutput: (d) => log('output ${jsonEncode(d)}'),
    onResize: (w, h, pw, ph) => log('resize $w $h $pw $ph'),
    onPrivateOSC: (c, a) => log('privOSC $c ${jsonEncode(a)}'),
    onUnknownSequence: (raw) => unknown.add(raw),
  )..resize(100, 37);
  terminal.onReply = (d) => log('reply ${jsonEncode(d)}');
  var notify = 0;
  terminal.addListener(() => notify++);

  void write(String s, int index) {
    try {
      terminal.write(s);
    } catch (e) {
      log('EXCEPTION at write $index: ${e.runtimeType} $e');
    }
  }

  for (var i = 0; i < chunks.length; i++) {
    write(chunks[i], i);
  }
  // OSC 52 reads answer through a Future; let them land.
  await Future<void>.delayed(Duration.zero);
  final state = _Hash();
  final dump = StringBuffer();
  _digestTerminal(terminal, state, full ? dump : null);
  log('--- probe');
  write(probe, -1);
  await Future<void>.delayed(Duration.zero);
  _digestTerminal(terminal, state, full ? dump : null);

  final eventHash = _Hash();
  for (final e in events) {
    eventHash.addString(e);
    if (full) dump.writeln('E $e');
  }
  final unknownHash = _Hash();
  for (final u in unknown) {
    unknownHash.addString(u);
    if (full) dump.writeln('U $u');
  }
  return (
    state: '$state',
    events: '$eventHash',
    unknown: '$unknownHash',
    notify: notify,
    dump: '$dump',
  );
}

void _digestTerminal(Terminal t, _Hash h, StringBuffer? dump) {
  void kv(String k, Object? v) {
    final s = '$k=$v';
    h.addString(s);
    dump?.writeln(s);
  }

  kv('view', '${t.viewWidth}x${t.viewHeight}');
  kv('alt', t.isUsingAltBuffer);
  final c = t.cursor;
  kv(
      'cursorStyle',
      '${c.foreground} ${c.background} ${c.underlineColor} '
          '${c.attrs} ${c.hyperlinkId} ${c.semanticAttrs}');
  kv('modes', [
    t.insertMode, t.lineFeedMode, t.cursorKeysMode, t.reverseDisplayMode, //
    t.originMode, t.autoWrapMode, t.reverseWrapMode,
    t.reverseWrapExtendedMode, t.mouseMode, t.mouseReportMode,
    t.cursorBlinkMode, t.cursorVisibleMode, t.appKeypadMode,
    t.ignoreKeypadWithNumLockMode, t.backarrowKeyMode, t.reportFocusMode,
    t.mouseShiftCaptureMode, t.altBufferMouseScrollMode, t.altEscPrefixMode,
    t.altSendsEscapeMode, t.bracketedPasteMode, t.inBandSizeReportMode,
    t.reportColorSchemeMode, t.graphemeClusterMode, t.kittyKeyboardMode,
    t.modifyOtherKeysMode, t.reflowEnabled, t.applicationCursorType,
    t.cursorLineHighlightMode,
  ]);
  kv(
      'colors',
      '${t.colorRevision} ${t.indexedColorOverrides.toList()} '
          '${t.specialColorOverrides.toList()} ${t.foregroundColorOverride} '
          '${t.backgroundColorOverride} ${t.cursorColorOverride} '
          '${t.selectionColorOverride} ${t.selectionForegroundColorOverride}');
  final s = t.semanticPromptState;
  kv(
      'semantic',
      '${s.content} ${s.lastCommandExitCode} ${s.aid} '
          '${s.promptKind} ${s.clickMode} ${s.redraw} ${s.specialKey} '
          '${s.commandLine}');

  for (final (name, b) in [('main', t.mainBuffer), ('alt', t.altBuffer)]) {
    kv(
        name,
        'h=${b.height} cur=${b.cursorX},${b.cursorY} '
        'margins=${b.marginTop},${b.marginBottom},${b.marginLeft},'
        '${b.marginRight} scrollBack=${b.scrollBack} '
        'ascii=${b.charset.isAscii}');
    for (var y = 0; y < b.height; y++) {
      final line = b.lines[y];
      h.add(line.isWrapped ? 1 : 0);
      h.add(line.length);
      final row = dump == null
          ? null
          : StringBuffer('$name $y '
              '${line.isWrapped ? 'w' : '-'}');
      for (var x = 0; x < line.length; x++) {
        final content = line.getContent(x);
        final fg = line.getForeground(x);
        final bg = line.getBackground(x);
        final attrs = line.getAttributes(x);
        final link = line.getHyperlinkId(x);
        final ul = line.getUnderlineColor(x);
        final sem = line.getSemanticContent(x);
        final combining = line.getCombiningCharacters(x);
        h
          ..add(content)
          ..add(fg)
          ..add(bg)
          ..add(attrs)
          ..add(link)
          ..add(ul)
          ..add(sem)
          ..addString(combining);
        row?.write(' ${content.toRadixString(16)}/${fg.toRadixString(16)}/'
            '${bg.toRadixString(16)}/${attrs.toRadixString(16)}/$link/'
            '${ul.toRadixString(16)}/$sem${combining == null ? '' : '+'
                '${combining.runes.map((r) => r.toRadixString(16)).join('+')}'}');
      }
      if (row != null) dump!.writeln(row);
    }
  }
}

({String hash, String dump}) _runDebugger(
    String input, String chunking, String name, int limit, bool full) {
  final text = input.length > limit ? input.substring(0, limit) : input;
  final debugger = TerminalDebugger();
  final h = _Hash();
  final dump = StringBuffer();
  final chunks = _split(text, chunking, name);
  for (var i = 0; i < chunks.length; i++) {
    try {
      debugger.write(chunks[i]);
    } catch (e) {
      final s = 'EXCEPTION at write $i: ${e.runtimeType} $e';
      h.addString(s);
      if (full) dump.writeln('D $s');
    }
  }
  for (final c in debugger.commands) {
    h
      ..add(c.start)
      ..add(c.end)
      ..addString(c.chars)
      ..add(c.error ? 1 : 0);
    for (final e in c.explanation) {
      h.addString(e);
    }
    if (full) {
      dump.writeln('D ${c.start}-${c.end} ${jsonEncode(c.chars)} '
          '${c.error} ${c.explanation.join(' | ')}');
    }
  }
  return (hash: '$h', dump: '$dump');
}
