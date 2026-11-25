import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm3/src/utils/debugger.dart';
import 'package:xterm3/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.setLinesPerPage(24));
      verify(parser.handler.setColumnsPerPage(80));
    });

    test('parses DECSCUSR with its space intermediate', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[5 q');

      verify(handler.setCursorShape(5)).called(1);
    });

    test('parses cursor tabulation control', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[W\x1b[2W\x1b[5W\x1b[?5W');

      verify(handler.setTapStop()).called(1);
      verify(handler.clearTabStopUnderCursor()).called(1);
      verify(handler.clearAllTabStops()).called(1);
      verify(handler.resetTabStops()).called(1);
    });

    test('parses cursor position aliases', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[4`\x1b[2a\x1b[3e');

      verify(handler.setCursorX(3)).called(1);
      verify(handler.moveCursorX(2)).called(1);
      verify(handler.moveCursorY(3)).called(1);
    });

    test('parses ANSI keyboard action mode', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[2h\x1b[2l');

      verify(handler.setKeyboardActionMode(true)).called(1);
      verify(handler.setKeyboardActionMode(false)).called(1);
    });

    test('parses ANSI send receive mode', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[12h\x1b[12l');

      verify(handler.setSendReceiveMode(true)).called(1);
      verify(handler.setSendReceiveMode(false)).called(1);
    });

    test('parses DEC private mode save and restore', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[?7;25s\x1b[?7;25r');

      verify(handler.saveDecMode(7)).called(1);
      verify(handler.saveDecMode(25)).called(1);
      verify(handler.restoreDecMode(7)).called(1);
      verify(handler.restoreDecMode(25)).called(1);
    });

    test('parses DEC enable column mode', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[?40h\x1b[?40l');

      verify(handler.setEnableColumnMode(true)).called(1);
      verify(handler.setEnableColumnMode(false)).called(1);
    });

    test('parses DEC slow scroll and autorepeat modes', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[?4h\x1b[?4l\x1b[?8h\x1b[?8l');

      verify(handler.setSlowScrollMode(true)).called(1);
      verify(handler.setSlowScrollMode(false)).called(1);
      verify(handler.setAutoRepeatMode(true)).called(1);
      verify(handler.setAutoRepeatMode(false)).called(1);
    });

    test('parses XTSHIFTESCAPE mouse shift capture', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[>1s\x1b[>0s\x1b[>s\x1b[>2s');

      verify(handler.setMouseShiftCaptureMode(true)).called(1);
      verify(handler.setMouseShiftCaptureMode(false)).called(2);
      verifyNever(handler.setMouseShiftCaptureMode(null));
    });

    test('parses DEC left and right margin mode', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[?69h\x1b[?69l');

      verify(handler.setLeftRightMarginMode(true)).called(1);
      verify(handler.setLeftRightMarginMode(false)).called(1);
    });

    test('parses DEC left and right margins', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[2;5s\x1b[3s');

      verify(handler.setLeftRightMargins(1, 4)).called(1);
      verify(handler.setLeftRightMargins(2, null)).called(1);
    });

    test('parses page size sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[100\$|\x1b[\$|\x1b[30t\x1b[36*|');

      verify(handler.setColumnsPerPage(100)).called(1);
      verify(handler.setColumnsPerPage(80)).called(1);
      verify(handler.setLinesPerPage(30)).called(1);
      verify(handler.setLinesPerPage(36)).called(1);
    });

    test('parses DEC color assignment sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[1;7;0,|\x1b[3;4;5,}');

      verify(handler.setAssignedColor(1, 7, 0)).called(1);
      verify(handler.setAlternateTextColor(3, 4, 5)).called(1);
    });

    test('parses column insert and delete sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write("\x1b[2'}\x1b['~");

      verify(handler.insertColumns(2)).called(1);
      verify(handler.deleteColumns(1)).called(1);
    });

    test('parses rectangular erase and fill sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b[2;3;4;5\$z'
        '\x1b[42;2;3;4;5\$x'
        '\x1b[2;3;4;5\${',
      );

      verify(handler.eraseRect(2, 3, 4, 5)).called(1);
      verify(handler.fillRect(42, 2, 3, 4, 5)).called(1);
      verify(handler.selectiveEraseRect(2, 3, 4, 5)).called(1);
    });

    test('parses rectangular copy sequence', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[2;3;4;5;1;6;7;1\$v\x1b["v');

      verify(handler.copyRect(2, 3, 4, 5, 1, 6, 7, 1)).called(1);
      verify(handler.sendWindowReport()).called(1);
    });

    test('parses terminal state report sequence', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[1\$u');

      verify(handler.sendTerminalStateReport(1)).called(1);
    });

    test('parses presentation state report sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[1\$w\x1b[2\$w');

      verify(handler.sendPresentationStateReport(1)).called(1);
      verify(handler.sendPresentationStateReport(2)).called(1);
    });

    test('parses user-preferred supplemental set sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[&u\x1bP1!uB\x1b\\');

      verify(handler.sendUserPreferredSupplementalSet()).called(1);
      verify(handler.assignUserPreferredSupplementalSet(96, 'B')).called(1);
    });

    test('parses rectangular checksum sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[7;1*y\x1b[8;1;2;3;4;5*y');

      verify(handler.sendRectChecksum(7, 1, null, null, null, null)).called(1);
      verify(handler.sendRectChecksum(8, 1, 2, 3, 4, 5)).called(1);
    });

    test('parses rectangular attribute sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b[2*x'
        '\x1b[2;3;4;5;7\$r'
        '\x1b[2;3;4;5;7\$t',
      );

      verify(handler.setAttributeChangeExtent(true)).called(1);
      verify(handler.changeRectAttributes(2, 3, 4, 5, 7)).called(1);
      verify(handler.reverseRectAttributes(2, 3, 4, 5, 7)).called(1);
    });

    test('parses VT520 bell volume sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[3 r\x1b[4 u\x1b[5 t');

      verify(handler.setKeyClickVolume(3)).called(1);
      verify(handler.setMarginBellVolume(4)).called(1);
      verify(handler.setWarningBellVolume(5)).called(1);
    });

    test('parses VT520 lock key and emulation sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[2 v\x1b[1 ~');

      verify(handler.setLockKeyStyle(2)).called(1);
      verify(handler.setTerminalModeEmulation(1)).called(1);
    });

    test('parses status line sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[1\$}\x1b[2\$~');

      verify(handler.setActiveStatusDisplay(1)).called(1);
      verify(handler.setStatusLineType(2)).called(1);
    });

    test('parses conformance level sequence', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[65;1"p');

      verify(handler.setConformanceLevel(65, 1)).called(1);
    });

    test('parses protected fields attribute sequence', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[1}');

      verify(handler.setProtectedFieldsAttribute(1)).called(1);
    });

    test('parses transmit termination character sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[13|\x1b[10\'s');

      verify(handler.setTransmitTerminationCharacter(13)).called(1);
      verify(handler.setLineTransmitTerminationCharacter(10)).called(1);
    });

    test('parses title mode sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[>2t\x1b[>2T');

      verify(handler.setTitleMode(2, true)).called(1);
      verify(handler.setTitleMode(2, false)).called(1);
    });

    test('parses protected mode and selective erase', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[1"q\x1b[2"q\x1b[?J\x1b[?1J\x1b[?2J');
      parser.write('\x1b[?K\x1b[?1K\x1b[?2K');

      verify(handler.setProtectedMode(true)).called(1);
      verify(handler.setProtectedMode(false)).called(1);
      verify(handler.eraseDisplayBelowSelective()).called(1);
      verify(handler.eraseDisplayAboveSelective()).called(1);
      verify(handler.eraseDisplaySelective()).called(1);
      verify(handler.eraseLineRightSelective()).called(1);
      verify(handler.eraseLineLeftSelective()).called(1);
      verify(handler.eraseLineSelective()).called(1);
    });

    test('parses scroll-complete erase display', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[22J\x1b[?22J');

      verify(handler.eraseDisplayScrollComplete()).called(1);
      verifyNever(handler.eraseDisplaySelective());
    });

    test('parses ISO protected areas', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1bV\x1bW');

      verify(handler.setIsoProtectedMode(true)).called(1);
      verify(handler.setIsoProtectedMode(false)).called(1);
    });

    test('parses grapheme cluster mode', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[?2027h\x1b[?2027l');

      verify(handler.setGraphemeClusterMode(true)).called(1);
      verify(handler.setGraphemeClusterMode(false)).called(1);
    });

    test('parses Ghostty reporting modes', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b[?1035h\x1b[?1035l'
        '\x1b[?1036h\x1b[?1036l'
        '\x1b[?1039h\x1b[?1039l'
        '\x1b[?2031h\x1b[?2031l'
        '\x1b[?2048h\x1b[?2048l',
      );

      verify(handler.setIgnoreKeypadWithNumLockMode(true)).called(1);
      verify(handler.setIgnoreKeypadWithNumLockMode(false)).called(1);
      verify(handler.setAltEscPrefixMode(true)).called(1);
      verify(handler.setAltEscPrefixMode(false)).called(1);
      verify(handler.setAltSendsEscapeMode(true)).called(1);
      verify(handler.setAltSendsEscapeMode(false)).called(1);
      verify(handler.setReportColorSchemeMode(true)).called(1);
      verify(handler.setReportColorSchemeMode(false)).called(1);
      verify(handler.setInBandSizeReportMode(true)).called(1);
      verify(handler.setInBandSizeReportMode(false)).called(1);
    });

    test('parses G2 and G3 character set controls', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b*0\x1b+0\x1bN\x1bO\x1bn\x1bo');

      verify(handler.designateCharset(2, 0x30)).called(1);
      verify(handler.designateCharset(3, 0x30)).called(1);
      verify(handler.singleShiftCharset(2)).called(1);
      verify(handler.singleShiftCharset(3)).called(1);
      verify(handler.useCharset(2)).called(1);
      verify(handler.useCharset(3)).called(1);
    });

    test('executes controls while waiting for charset final byte', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b(\x07\x7f0');

      verify(handler.bell()).called(1);
      verify(handler.designateCharset(0, 0x30)).called(1);
    });

    test('preserves split charset sequence across controls', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b(');
      parser.write('\x0e0');

      verify(handler.shiftOut()).called(1);
      verify(handler.designateCharset(0, 0x30)).called(1);
    });

    test('restarts escape while waiting for charset final byte', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b(\x1b[5 q');

      verifyNever(handler.designateCharset(any, any));
      verify(handler.setCursorShape(5)).called(1);
    });

    test('executes controls while waiting for hash final byte', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b#\x078');

      verify(handler.bell()).called(1);
      verify(handler.screenAlignmentTest()).called(1);
    });

    test('rejects malformed plain CSI commands', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b[?2A'
        '\x1b[1;2A'
        '\x1b[2 A'
        '\x1b[>31m'
        '\x1b[?4m'
        '\x1b[?1L',
      );

      verifyNever(handler.moveCursorY(any));
      verifyNever(handler.setCursorBold());
      verifyNever(handler.insertLines(any));
    });

    test('parses horizontal position backward alias', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[3j');

      verify(handler.moveCursorX(-3)).called(1);
    });

    test('parses back and forward index escapes', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b6\x1b9');

      verify(handler.backIndex()).called(1);
      verify(handler.forwardIndex()).called(1);
    });

    test('parses 8-bit C1 controls', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\u0084\u0085\u0088\u008d\u008e\u008f\u009b2A');

      verify(handler.index()).called(1);
      verify(handler.nextLine()).called(1);
      verify(handler.setTapStop()).called(1);
      verify(handler.reverseIndex()).called(1);
      verify(handler.singleShiftCharset(2)).called(1);
      verify(handler.singleShiftCharset(3)).called(1);
      verify(handler.moveCursorY(-2)).called(1);
    });

    test('parses xterm special color OSCs', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b]5;1;#123456;2;?\x1b\\'
        '\x1b]105;1;2\x1b\\',
      );

      verify(handler.setSpecialColor(1, '#123456')).called(1);
      verify(handler.querySpecialColor(2)).called(1);
      verify(handler.resetSpecialColors([1, 2])).called(1);
    });

    test('parses xterm dynamic color OSCs', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write(
        '\x1b]13;#010203\x1b\\'
        '\x1b]17;#123456\x1b\\'
        '\x1b]18;#654321\x1b\\'
        '\x1b]19;?\x1b\\'
        '\x1b]113\x1b\\'
        '\x1b]117\x1b\\'
        '\x1b]118\x1b\\'
        '\x1b]119\x1b\\',
      );

      verify(handler.setDynamicColor(13, '#010203')).called(1);
      verify(handler.setDynamicColor(17, '#123456')).called(1);
      verify(handler.setDynamicColor(18, '#654321')).called(1);
      verify(handler.queryDynamicColor(19)).called(1);
      verify(handler.resetDynamicColor(13)).called(1);
      verify(handler.resetDynamicColor(17)).called(1);
      verify(handler.resetDynamicColor(18)).called(1);
      verify(handler.resetDynamicColor(19)).called(1);
    });
  });

  test('each character taken one at a time is a token of its own', () {
    // Wide and astral characters are taken in the same head-block scan as
    // runs and sequences; each must still start its own token.
    final debugger = TerminalDebugger()..write('漢😀\x1b[1m字');

    expect(
      [for (final c in debugger.commands) (c.start, c.end, c.chars)],
      [(0, 1, '漢'), (1, 2, '😀'), (2, 6, '\x1b[1m'), (6, 7, '字')],
    );
  });

  // Pins what CSI handlers receive for parameter lists of every shape. These
  // were recorded from the parser as it stood before its parameter storage
  // changed, and must keep passing unchanged: the storage is an internal
  // detail, the parameters a handler sees are not.
  group('CSI parameters reach handlers unchanged', () {
    List<String> calls(String input) {
      final debugger = TerminalDebugger()..write(input);
      return [for (final c in debugger.commands) ...c.explanation];
    }

    test('no parameters and one parameter', () {
      expect(calls('\x1b[m\x1b[H\x1b[A\x1b[r'), [
        'resetCursorStyle',
        'setCursor(0, 0)',
        'moveCursorY(-1)',
        'setMargins(0, null)',
      ]);
      expect(calls('\x1b[5A\x1b[7m\x1b[3J'), [
        'moveCursorY(-5)',
        'setCursorInverse',
        'eraseScrollbackOnly',
      ]);
    });

    test('32 parameters are all kept', () {
      expect(calls('\x1b[${'1;' * 31}3m'), [
        ...List.filled(31, 'setCursorBold'),
        'setCursorItalic',
      ]);
      expect(calls('\x1b[${';' * 31}3m'), [
        ...List.filled(31, 'resetCursorStyle'),
        'setCursorItalic',
      ]);
    });

    test('parameters past the 32nd are dropped', () {
      expect(calls('\x1b[${'1;' * 32}3m'), List.filled(32, 'setCursorBold'));
      expect(calls('\x1b[${'1;' * 99}3m'), List.filled(32, 'setCursorBold'));
      expect(
        calls('\x1b[${';' * 40}3m'),
        List.filled(32, 'resetCursorStyle'),
      );
    });

    test('a sequence longer than 256 code units is not dispatched', () {
      expect(calls('\x1b[${'22;' * 99}3mX'), ['writeChar(X)']);
    });

    test('huge values are clamped to 65535', () {
      expect(
        calls('\x1b[99999999999999999999A'
            '\x1b[65535;65536H'
            '\x1b[38;2;99999;300;1m'
            '\x1b[38;5;65536m'
            '\x1b[12345678901234567890;1m'),
        [
          'moveCursorY(-65535)',
          'setCursor(65534, 65534)',
          'unsupportedStyle(65535)',
          'setCursorBold',
        ],
      );
    });

    test('empty parameters read as 0', () {
      expect(
        calls('\x1b[;5H\x1b[1;;3m\x1b[;m\x1b[;;m\x1b[1;m\x1b[;1m'),
        [
          'setCursor(4, 0)',
          'setCursorBold',
          'resetCursorStyle',
          'setCursorItalic',
          ...List.filled(5, 'resetCursorStyle'),
          'setCursorBold',
          'resetCursorStyle',
          'resetCursorStyle',
          'setCursorBold',
        ],
      );
    });

    test('mixed ; and : separators', () {
      expect(
        calls('\x1b[4:3;38:2::10:20:30;58:5:9m'
            '\x1b[38:2:1:2:3m'
            '\x1b[48;2;1;2;3m'
            '\x1b[38:2:0:1:2:3m'
            '\x1b[4:3:1m'
            '\x1b[38;5;1:2m'),
        [
          'setCursorUndercurl',
          'setForegroundColorRgb(10, 20, 30)',
          'setUnderlineColor256(9)',
          'setForegroundColorRgb(1, 2, 3)',
          'setBackgroundColorRgb(1, 2, 3)',
          'setForegroundColorRgb(1, 2, 3)',
          'setCursorUndercurl',
          'setCursorBold',
          'setForegroundColor256(1)',
          'setCursorFaint',
        ],
      );
    });

    test('a long sequence leaves nothing behind for the next one', () {
      final colons = List.generate(32, (i) => i + 1).join(':');
      expect(
        calls('\x1b[38:2:${colons}m'
            '\x1b[38:5m\x1b[4m\x1b[38;2;1m\x1b[58:2::1:2m\x1b[1;2H'),
        [
          'setForegroundColorRgb(2, 3, 4)',
          'setCursorBlink',
          'setCursorBlink',
          'setCursorInverse',
          'setCursorInvisible',
          'setCursorStrikethrough',
          for (var i = 10; i <= 20; i++) 'unsupportedStyle($i)',
          'setCursorDoubleUnderline',
          'unsetCursorBold',
          'unsetCursorFaint',
          'unsetCursorItalic',
          'unsetCursorUnderline',
          'unsetCursorBlink',
          'unsupportedStyle(26)',
          'unsetCursorInverse',
          'unsetCursorInvisible',
          'unsetCursorStrikethrough',
          'setForegroundColor16(0)',
          'setCursorUnderline',
          'setUnderlineColorRgb(0, 1, 2)',
          'setCursor(1, 0)',
        ],
      );
    });

    test('a private device status report gets its parameters as a list', () {
      expect(calls('\x1b[?6n\x1b[?63;1n\x1b[?6;2n\x1b[?15n\x1b[?n'), [
        'sendPrivateDeviceStatusReport([6])',
        'sendPrivateDeviceStatusReport([63, 1])',
        'sendPrivateDeviceStatusReport([15])',
      ]);

      final handler = _DsrRecorder();
      EscapeParser(handler).write('\x1b[?63;1n');
      final params = handler.received!;
      expect(params, [63, 1]);
      // An ordinary growable list, as it always was.
      params.add(7);
      expect(params, [63, 1, 7]);
    });
  });
}

class _DsrRecorder extends MockEscapeHandler {
  List<int>? received;

  @override
  void sendPrivateDeviceStatusReport(List<int> params) => received = params;
}
