import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/raccoon_view.dart';

class _ComposingConnection implements RunnerConnection, ComposingConnection {
  final fields = StreamController<rc.TextField>.broadcast();
  final editings = <rc.TextEditing>[];
  final keys = <rc.KeyEvent>[];

  @override
  bool get composes => true;

  @override
  Stream<rc.Frame> get frames => const Stream.empty();

  @override
  Stream<rc.TextField> get textFields => fields.stream;

  @override
  rc.TextField? get latestTextField => null;

  @override
  void resize(int width, int height, double pixelRatio) {}

  @override
  void sendPointer(rc.PointerEvent event) {}

  @override
  void sendKey(rc.KeyEvent event) => keys.add(event);

  @override
  void sendTextEditing(rc.TextEditing editing) => editings.add(editing);
}

rc.TextField _field({
  bool active = true,
  String text = '',
  int base = 0,
  int extent = 0,
  int composingBase = -1,
  int composingExtent = -1,
}) => rc.TextField(
  active: active,
  text: text,
  selectionBase: base,
  selectionExtent: extent,
  composingBase: composingBase,
  composingExtent: composingExtent,
  inputAction: 'TextInputAction.done',
);

void main() {
  testWidgets(
    'an active field opens the host input method, which types through it',
    (tester) async {
      final connection = _ComposingConnection();
      await tester.pumpWidget(
        RaccoonView(connection: connection, autofocus: true),
      );
      expect(tester.testTextInput.hasAnyClients, isFalse);

      connection.fields.add(_field());
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);

      // The method composes, then commits.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'tiế',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        ),
      );
      await tester.pump();
      expect(connection.editings.last.text, 'tiế');
      expect(connection.editings.last.composingBase, 0);
      expect(connection.editings.last.composingExtent, 3);
      tester.testTextInput.enterText('tiếng');
      await tester.pump();
      expect(connection.editings.last.text, 'tiếng');
      expect(connection.editings.last.composingBase, -1);

      // The app's own change comes back into the method.
      connection.fields.add(_field(text: 'tiến', base: 4, extent: 4));
      await tester.pump();
      expect(tester.testTextInput.editingState?['text'], 'tiến');

      connection.fields.add(_field(active: false));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
    },
  );

  testWidgets('editing keys stay with the app unless the method is composing', (
    tester,
  ) async {
    final connection = _ComposingConnection();
    await tester.pumpWidget(
      RaccoonView(connection: connection, autofocus: true),
    );
    connection.fields.add(_field());
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(
      connection.keys.where((k) => k.logical.toInt() == 0x100000008),
      hasLength(2),
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ti',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    connection.keys.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(connection.keys, isEmpty);
  });

  // #97: a release build crashed the host in the engine's setEditingState.
  testWidgets(
    'a host field takes the method; the view takes it back on focus',
    (tester) async {
      final connection = _ComposingConnection();
      final hostFocus = FocusNode();
      final hostText = TextEditingController();
      addTearDown(hostFocus.dispose);
      addTearDown(hostText.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SizedBox(
                height: 40,
                child: EditableText(
                  controller: hostText,
                  focusNode: hostFocus,
                  style: const TextStyle(),
                  cursorColor: const Color(0xFF000000),
                  backgroundCursorColor: const Color(0xFF000000),
                ),
              ),
              Expanded(
                child: RaccoonView(connection: connection, autofocus: true),
              ),
            ],
          ),
        ),
      );
      connection.fields.add(_field(text: 'app'));
      await tester.pump();
      expect(tester.testTextInput.editingState?['text'], 'app');

      hostFocus.requestFocus();
      await tester.pump();
      hostFocus.unfocus();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);

      // The app's field changes while the host's method has no client.
      tester.testTextInput.log.clear();
      connection.fields.add(_field(text: 'apps', base: 4, extent: 4));
      await tester.pump();
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.setEditingState')),
      );

      await tester.tap(find.byType(RaccoonView));
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.editingState?['text'], 'apps');
    },
  );

  // #133: a password field that took over from another, the method still
  // open, kept the first field's settings.
  testWidgets('a field taking over gives the method its own settings', (
    tester,
  ) async {
    final connection = _ComposingConnection();
    await tester.pumpWidget(
      RaccoonView(connection: connection, autofocus: true),
    );
    connection.fields.add(_field(text: 'simon'));
    await tester.pump();
    tester.testTextInput.log.clear();

    connection.fields.add(_field()..obscure = true);
    await tester.pump();
    final updates = tester.testTextInput.log.where(
      (call) => call.method == 'TextInput.updateConfig',
    );
    expect(updates, hasLength(1));
    expect((updates.single.arguments as Map)['obscureText'], isTrue);
  });
}
