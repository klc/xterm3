import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/src/ui/shortcut/shortcuts.dart';

void main() {
  test('non-Apple clipboard shortcuts preserve terminal control keys', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final shortcuts = defaultTerminalShortcuts;
    final pasteShortcut = shortcuts.entries
        .where((entry) => entry.value is PasteTextIntent)
        .map((entry) => entry.key)
        .whereType<SingleActivator>()
        .single;
    final selectAllShortcut = shortcuts.entries
        .where((entry) => entry.value is SelectAllTextIntent)
        .map((entry) => entry.key)
        .whereType<SingleActivator>()
        .single;

    expect(pasteShortcut.trigger, LogicalKeyboardKey.keyV);
    expect(pasteShortcut.control, isTrue);
    expect(pasteShortcut.shift, isTrue);
    expect(selectAllShortcut.trigger, LogicalKeyboardKey.keyA);
    expect(selectAllShortcut.control, isTrue);
    expect(selectAllShortcut.shift, isTrue);
  });
}
