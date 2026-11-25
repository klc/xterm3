import 'package:flutter/widgets.dart';

class CustomKeyboardListener extends StatelessWidget {
  final Widget child;

  final FocusNode focusNode;

  final bool autofocus;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  const CustomKeyboardListener({
    super.key,
    required this.child,
    required this.focusNode,
    this.autofocus = false,
    required this.onKeyEvent,
  });

  @override
  Widget build(BuildContext context) {
    // onKeyEvent inserts printable text itself; a key it ignores (a Cmd or
    // Ctrl shortcut) must stay ignored so it reaches ancestor shortcuts.
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: onKeyEvent,
      child: child,
    );
  }
}
