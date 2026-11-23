import 'package:flutter/widgets.dart';

class KeyboardVisibilty extends StatefulWidget {
  const KeyboardVisibilty({
    super.key,
    required this.child,
    this.onKeyboardShow,
    this.onKeyboardHide,
  });

  final Widget child;

  final VoidCallback? onKeyboardShow;

  final VoidCallback? onKeyboardHide;

  @override
  KeyboardVisibiltyState createState() => KeyboardVisibiltyState();
}

class KeyboardVisibiltyState extends State<KeyboardVisibilty>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A view mounted with the keyboard already open starts out shown.
    _lastBottomInset = View.of(context).viewInsets.bottom;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final bottomInset = View.of(context).viewInsets.bottom;

    // Only the edges count: an animated keyboard reports every frame of its
    // slide, and a keyboard that changes height stays shown.
    if (_lastBottomInset == 0 && bottomInset > 0) {
      widget.onKeyboardShow?.call();
    } else if (_lastBottomInset > 0 && bottomInset == 0) {
      widget.onKeyboardHide?.call();
    }

    _lastBottomInset = bottomInset;

    super.didChangeMetrics();
  }

  var _lastBottomInset = 0.0;

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
