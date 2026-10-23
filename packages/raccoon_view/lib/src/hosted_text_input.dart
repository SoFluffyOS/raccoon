import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show FocusNode;
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_runtime/raccoon_runtime.dart' show ComposingConnection;

/// The hosted app's active text field, mirrored in the host's own input
/// method: while the view has focus, the host attaches a text input
/// connection for the field, keeps its editing value equal to the field's,
/// and sends what the input method produces, composition included, back to
/// the runner. A host field that takes the method takes it for good; the
/// view takes it back when it gets focus again.
final class HostedTextInput with TextInputClient {
  HostedTextInput(this._connection, this._focus) {
    _focus.addListener(_onFocus);
  }

  final ComposingConnection _connection;
  final FocusNode _focus;
  TextInputConnection? _host;
  rc.TextField? _field;
  TextEditingValue _value = TextEditingValue.empty;

  /// Whether the host's input method is open for the hosted field.
  bool get attached => _host?.attached ?? false;

  /// Whether the input method is in the middle of composing text; then the
  /// editing keys belong to it, not to the app.
  bool get composing =>
      _value.composing.isValid && !_value.composing.isCollapsed;

  /// The app's field changed, or went away.
  void field(rc.TextField field) {
    if (!field.active) {
      _field = null;
      _close();
      return;
    }
    _field = field;
    if (_focus.hasFocus) _open(field);
  }

  void dispose() {
    _focus.removeListener(_onFocus);
    _field = null;
    _close();
  }

  void _onFocus() {
    final field = _field;
    if (!_focus.hasFocus) {
      _close();
    } else if (field != null) {
      _open(field);
    }
  }

  void _open(rc.TextField field) {
    final value = TextEditingValue(
      text: field.text,
      selection: TextSelection(
        baseOffset: field.selectionBase,
        extentOffset: field.selectionExtent,
      ),
      composing: switch ((field.composingBase, field.composingExtent)) {
        (final start, final end) when start >= 0 && end >= start => TextRange(
          start: start,
          end: end,
        ),
        _ => TextRange.empty,
      },
    );
    // A connection another client took is no longer ours to talk on: in a
    // release build its calls reach whatever client the engine has, or none,
    // and the macOS embedder crashes on none (#97).
    if (!attached) {
      _host = TextInput.attach(
        this,
        TextInputConfiguration(
          inputType: switch (field.multiline) {
            true => TextInputType.multiline,
            false => TextInputType.text,
          },
          obscureText: field.obscure,
          inputAction: _action(field.inputAction),
          autocorrect: false,
          enableSuggestions: false,
        ),
      )..show();
    } else if (value == _value) {
      return;
    }
    _value = value;
    _host?.setEditingState(value);
  }

  void _close() {
    _host?.close();
    _host = null;
    _value = TextEditingValue.empty;
  }

  static TextInputAction _action(String name) {
    for (final action in TextInputAction.values) {
      if (action.toString() == name) return action;
    }
    return TextInputAction.done;
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (value == _value) return;
    _value = value;
    _connection.sendTextEditing(
      rc.TextEditing(
        text: value.text,
        selectionBase: value.selection.baseOffset,
        selectionExtent: value.selection.extentOffset,
        composingBase: value.composing.isValid ? value.composing.start : -1,
        composingExtent: value.composing.isValid ? value.composing.end : -1,
      ),
    );
  }

  // Enter reaches the app as a key; the input method's action is not needed.
  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _host = null;
  }
}
