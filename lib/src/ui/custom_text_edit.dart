import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    int? viewId,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  }) : viewId = viewId ?? PlatformDispatcher.instance.implicitView?.viewId {
    if (this.viewId == null) {
      throw Exception('Cannot open input connection without a valid viewId.');
    }
  }

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  final int? viewId;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;

  /// Text synchronously written when an IME action arrived with an active
  /// composing range. Android may subsequently send the same text as a
  /// collapsed editing value; it must not reach the terminal twice.
  String? _actionCommittedText;

  /// The content of an open, not-yet-resolved composing range in
  /// [deleteDetection] mode - see [_updateEditingValueWithDeleteDetection].
  /// Non-null exactly while such a range is open and its fate (genuine
  /// preview vs. trapped keystroke) has not yet been decided.
  String? _pendingComposingText;

  /// The `composing.start` of [_pendingComposingText], used to tell a
  /// composing range that is being extended in place (same base, growing
  /// text - a real preview) from one that has been replaced by an unrelated
  /// fresh range at the same base (a trapped keystroke, see f6568e1).
  int? _pendingComposingBase;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  /// Drops any in-flight composition and restores the initial editing state.
  void resetEditingState() {
    widget.onComposing(null);
    _resetEditingState();
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (_currentEditingState.composing.isCollapsed) {
      return widget.onKeyEvent(focusNode, event);
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        viewId: widget.viewId,
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);

      _connection!.show();

      // setEditableRect(Rect.zero, Rect.zero);

      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: '  ',
          selection: TextSelection.collapsed(offset: 2),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentEditingState = value;

    if (widget.deleteDetection) {
      _updateEditingValueWithDeleteDetection(value);
      return;
    }

    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    final textDelta = _textDelta(_currentEditingState);
    final actionCommittedText = _actionCommittedText;

    if (actionCommittedText != null) {
      if (textDelta == actionCommittedText) {
        _actionCommittedText = null;
        _resetEditingState();
        return;
      }

      // Preserve input that arrives together with a delayed action commit.
      // This is uncommon, but it prevents losing a character if an IME batches
      // the next edit with its final composition commit.
      if (textDelta.startsWith(actionCommittedText)) {
        _actionCommittedText = null;
        final remainingText = textDelta.substring(actionCommittedText.length);
        if (remainingText.isNotEmpty) {
          widget.onInsert(remainingText);
        }
        _resetEditingState();
        return;
      }

      _actionCommittedText = null;
    }

    if (_currentEditingState.text.length < _initEditingState.text.length) {
      widget.onDelete();
    } else if (textDelta.isEmpty &&
        _currentEditingState.text == _initEditingState.text) {
      // The local buffer is already at its floor (empty, cursor at 0), so
      // there is nothing left for a backspace to shorten. Some soft
      // keyboards still emit this exact no-op editing value for that
      // keypress instead of staying silent - treat it as the delete it
      // represents rather than as an empty insert.
      widget.onDelete();
    } else {
      widget.onInsert(textDelta);
    }

    // Reset editing state if composing is done
    if (_currentEditingState.composing.isCollapsed &&
        _currentEditingState.text != _initEditingState.text) {
      _resetEditingState();
    }
  }

  /// Handles [updateEditingValue] for [CustomTextEdit.deleteDetection] mode.
  ///
  /// This mode pads the editing state with a sentinel (see
  /// [_initEditingState]) so a backspace at offset 0 always has something to
  /// remove, letting the deletion be derived from how much of the sentinel
  /// is left rather than from a raw text-length diff against empty.
  ///
  /// Composition must still work here. While `value.composing` is a genuine,
  /// still-open multi-character preview, emission is deferred and only the
  /// text the IME actually commits is emitted once composing closes.
  ///
  /// The complication is the pattern some Android keyboards (Gboard,
  /// Samsung, SwiftKey) produce for a single already-resolved keypress: they
  /// wrap it in a composing range that never collapses on its own (fixed by
  /// f6568e1). Such a range opens fresh with exactly one character in it -
  /// but so does a genuine preview, on its very first keystroke. A bare
  /// length check can't tell those apart, so instead this tracks whether an
  /// open composing range is being *extended in place*:
  ///
  ///   - a range whose base stays put and whose text keeps growing is a
  ///     real, still-open preview - keep deferring.
  ///   - a range that collapses is a resolved commit - emit it once.
  ///   - a *different* range appearing at the same base without the
  ///     previous one ever growing or collapsing is the f6568e1 shape: the
  ///     previous keystroke was already resolved and is never coming back,
  ///     so it is flushed now instead of waiting for a collapse that will
  ///     never arrive.
  void _updateEditingValueWithDeleteDetection(TextEditingValue value) {
    final text = value.text;
    final initLength = _initEditingState.text.length;

    if (value.composing.isValid) {
      final composingText = value.composing.textInside(text);
      final base = value.composing.start;
      final pending = _pendingComposingText;

      final isExtendingPending = pending != null &&
          base == _pendingComposingBase &&
          composingText.length > pending.length;

      if (isExtendingPending) {
        _pendingComposingText = composingText;
        widget.onComposing(composingText);
        return;
      }

      if (pending != null && pending.length > 1) {
        // The pending range already held more than one character, so it was
        // never an ambiguous fresh single-keystroke open - it was already a
        // confirmed, substantial preview (e.g. a pinyin buffer). Replacing
        // it wholesale, even with something shorter, is an ordinary step in
        // the same composition (e.g. picking a hanzi candidate), not the
        // f6568e1 trapped-keystroke shape, which only ever involves single
        // characters. Keep deferring.
        _pendingComposingText = composingText;
        _pendingComposingBase = base;
        widget.onComposing(composingText);
        return;
      }

      if (pending != null) {
        // The pending range was a single, unconfirmed character and has now
        // been replaced by another fresh range without ever growing or
        // collapsing - the previous keystroke is done and will never
        // collapse on its own (f6568e1), so flush it now. The replacement
        // is exactly as resolved as the one it replaced (nothing else has
        // arrived to prove otherwise), so it is flushed immediately too
        // rather than reopened as a new pending range.
        if (pending.isNotEmpty) {
          widget.onInsert(pending);
        }
        if (composingText.isNotEmpty) {
          widget.onInsert(composingText);
        }
        widget.onComposing(null);
        _resetEditingState();
        return;
      }

      // Freshly opened range, nothing pending yet. This might be the start
      // of a genuine preview or a trapped keystroke - hold it pending and
      // let the next update (extension, collapse, or replacement above)
      // decide, instead of assuming either way.
      _pendingComposingText = composingText;
      _pendingComposingBase = base;
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);
    _pendingComposingText = null;
    _pendingComposingBase = null;

    if (text.length < initLength) {
      final deleteCount = initLength - text.length;
      for (var i = 0; i < deleteCount; i++) {
        widget.onDelete();
      }
      _resetEditingState();
      return;
    }

    if (text.length > initLength) {
      final textDelta = text.substring(initLength);
      if (textDelta.isNotEmpty) {
        widget.onInsert(textDelta);
      }
      _resetEditingState();
      return;
    }

    if (text != _initEditingState.text) {
      _resetEditingState();
    }
  }

  @override
  void performAction(TextInputAction action) {
    _commitComposingTextForAction();
    widget.onAction(action);
  }

  String _textDelta(TextEditingValue value) {
    final initialTextLength = _initEditingState.text.length;
    if (value.text.length < initialTextLength) {
      return '';
    }

    return value.text.substring(initialTextLength);
  }

  void _commitComposingTextForAction() {
    if (_currentEditingState.composing.isCollapsed) {
      return;
    }

    final textDelta = _textDelta(_currentEditingState);
    widget.onComposing(null);

    if (textDelta.isNotEmpty) {
      widget.onInsert(textDelta);
      _actionCommittedText = textDelta;
    }

    _resetEditingState();
  }

  void _resetEditingState() {
    _currentEditingState = _initEditingState;
    _pendingComposingText = null;
    _pendingComposingBase = null;
    _connection?.setEditingState(_initEditingState);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    // print('connectionClosed');
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
