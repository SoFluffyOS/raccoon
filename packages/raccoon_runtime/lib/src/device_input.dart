import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:raccoon/raccoon.dart';
import 'package:raccoon_runtime/src/runner_connection.dart';

/// Input to an app on a runner in logical pixels, as a person's finger,
/// mouse wheel, keyboard and input method give it: taps, long presses,
/// drags, wheel turns, text and keys. The test harness, the simulator's
/// control endpoint and any other host send it the same way.
///
/// [pixelRatio] is read at every event, so a host that resizes the app
/// between two calls maps each in the size it has then.
final class RaccoonInput {
  RaccoonInput(
    this.connection, {
    required double Function() pixelRatio,
    this.name = 'the app',
  }) : _pixelRatio = pixelRatio;

  /// Where the events go.
  final ComposingConnection connection;

  /// What error messages call the app: `hello@phone`.
  final String name;

  final double Function() _pixelRatio;

  // Pointer ids per connection, so two inputs on one never share an id.
  static final _nextPointer = Expando<int>();

  int _pointer() {
    final id = _nextPointer[connection] ?? 1;
    _nextPointer[connection] = id + 1;
    return id;
  }

  /// Taps at ([x], [y]).
  Future<void> tap(double x, double y) async {
    final id = _pointer();
    _touch(PointerPhase.POINTER_PHASE_DOWN, x, y, id);
    _touch(PointerPhase.POINTER_PHASE_UP, x, y, id);
  }

  /// Presses at ([x], [y]) for [hold], longer than Flutter's long press
  /// takes (500 ms).
  Future<void> longPress(
    double x,
    double y, {
    Duration hold = const Duration(milliseconds: 650),
  }) async {
    final id = _pointer();
    _touch(PointerPhase.POINTER_PHASE_DOWN, x, y, id);
    await Future<void>.delayed(hold);
    _touch(PointerPhase.POINTER_PHASE_UP, x, y, id);
  }

  /// Drags a finger from ([fromX], [fromY]) to ([toX], [toY]) over
  /// [duration], in [steps] moves, then lifts it: a fling when short and
  /// fast, a pan when slow.
  Future<void> drag(
    double fromX,
    double fromY,
    double toX,
    double toY, {
    Duration duration = const Duration(milliseconds: 300),
    int steps = 20,
  }) async {
    final id = _pointer();
    final count = steps < 1 ? 1 : steps;
    _touch(PointerPhase.POINTER_PHASE_DOWN, fromX, fromY, id);
    for (var i = 1; i <= count; i++) {
      await Future<void>.delayed(duration ~/ count);
      final t = i / count;
      _touch(
        PointerPhase.POINTER_PHASE_MOVE,
        fromX + (toX - fromX) * t,
        fromY + (toY - fromY) * t,
        id,
      );
    }
    _touch(PointerPhase.POINTER_PHASE_UP, toX, toY, id);
  }

  /// Turns a mouse wheel over ([x], [y]) by [dx], [dy] logical pixels:
  /// positive [dy] scrolls down the content, as a wheel turned towards the
  /// user does.
  Future<void> scroll(
    double x,
    double y, {
    double dx = 0,
    double dy = 0,
  }) async {
    final ratio = _pixelRatio();
    connection.sendPointer(
      PointerEvent(
        phase: PointerPhase.POINTER_PHASE_HOVER,
        x: x * ratio,
        y: y * ratio,
        device: PointerDevice.POINTER_DEVICE_MOUSE,
        pointerId: 0,
        scrollDeltaX: dx * ratio,
        scrollDeltaY: dy * ratio,
      ),
    );
  }

  /// Types [text] into the text field that has the focus, in place of its
  /// selection, as a host's input method does. Tap the field first.
  Future<void> typeText(
    String text, {
    Duration focusWait = const Duration(seconds: 5),
  }) async {
    final field = await _activeField(focusWait);
    final length = field.text.length;
    final base = field.selectionBase.clamp(0, length);
    final extent = field.selectionExtent.clamp(0, length);
    final start = base < extent ? base : extent;
    final end = base < extent ? extent : base;
    final caret = start + text.length;
    connection.sendTextEditing(
      TextEditing(
        text: field.text.replaceRange(start, end, text),
        selectionBase: caret,
        selectionExtent: caret,
        composingBase: -1,
        composingExtent: -1,
      ),
    );
  }

  /// Presses and releases [key], with [modifiers] held around it.
  Future<void> pressKey(
    RaccoonKey key, {
    List<RaccoonKey> modifiers = const [],
  }) async {
    // With shift held a letter types its capital, as on a keyboard.
    final shifted =
        key.character.length == 1 &&
        modifiers.any(
          (modifier) => modifier.physical == RaccoonKey.shift.physical,
        );
    final pressed =
        shifted
            ? RaccoonKey(key.physical, key.logical, key.character.toUpperCase())
            : key;
    for (final modifier in modifiers) {
      _key(modifier, KeyKind.KEY_KIND_DOWN);
    }
    _key(pressed, KeyKind.KEY_KIND_DOWN);
    _key(pressed, KeyKind.KEY_KIND_UP);
    for (final modifier in modifiers.reversed) {
      _key(modifier, KeyKind.KEY_KIND_UP);
    }
  }

  void _touch(PointerPhase phase, double x, double y, int id) {
    final ratio = _pixelRatio();
    connection.sendPointer(
      PointerEvent(
        phase: phase,
        x: x * ratio,
        y: y * ratio,
        buttons: Int64(phase == PointerPhase.POINTER_PHASE_UP ? 0 : 1),
        device: PointerDevice.POINTER_DEVICE_TOUCH,
        pointerId: id,
      ),
    );
  }

  void _key(RaccoonKey key, KeyKind kind) {
    connection.sendKey(
      KeyEvent(
        kind: kind,
        physical: Int64(key.physical),
        logical: Int64(key.logical),
        character: kind == KeyKind.KEY_KIND_DOWN ? key.character : '',
      ),
    );
  }

  Future<TextField> _activeField(Duration wait) async {
    if (connection.latestTextField case final field? when field.active) {
      return field;
    }
    return connection.textFields
        .firstWhere((field) => field.active)
        .timeout(
          wait,
          onTimeout:
              () =>
                  throw StateError(
                    'no text field has the focus on $name: tap one first',
                  ),
        );
  }
}

/// A key as Flutter knows it: its USB HID usage, its logical key id, and
/// the text it types.
final class RaccoonKey {
  const RaccoonKey(this.physical, this.logical, [this.character = '']);

  /// A printable character on a US keyboard, by itself: `a`, `7`, `.`.
  /// Shifted characters (`A`, `!`) need [shift] held;
  /// [RaccoonInput.typeText] types any text without keys.
  factory RaccoonKey.character(String character) {
    if (character.length != 1) {
      throw ArgumentError.value(character, 'character', 'one character');
    }
    final unit = character.toLowerCase().codeUnitAt(0);
    final physical = switch (unit) {
      >= 0x61 && <= 0x7a => 0x00070004 + unit - 0x61,
      >= 0x31 && <= 0x39 => 0x0007001e + unit - 0x31,
      0x30 => 0x00070027,
      _ => _punctuation[character] ?? 0,
    };
    if (physical == 0) {
      throw ArgumentError.value(character, 'character', 'no key types it');
    }
    return RaccoonKey(physical, unit, character);
  }

  /// A key by name, as a tool takes it: `enter`, `escape`, `backspace`,
  /// `tab`, `space`, `delete`, `home`, `end`, `page_up`, `page_down`,
  /// `arrow_left` (or `left`) and the other arrows, `shift`, `control`
  /// (`ctrl`), `alt` (`option`), `meta` (`cmd`, `command`, `super`), or one
  /// printable character. Case, dashes and underscores do not matter for
  /// names: `ArrowDown`, `arrow-down` and `arrow_down` are one key.
  factory RaccoonKey.named(String name) {
    if (name.length == 1) return RaccoonKey.character(name);
    final plain = name.toLowerCase().replaceAll(RegExp(r'[-_ ]'), '');
    if (_named[plain] case final key?) return key;
    throw ArgumentError.value(
      name,
      'key',
      'not a key: one character, or one of ${keyNames.join(', ')}',
    );
  }

  final int physical;
  final int logical;
  final String character;

  static const enter = RaccoonKey(0x00070028, 0x0010000000d, '\r');
  static const escape = RaccoonKey(0x00070029, 0x0010000001b);
  static const backspace = RaccoonKey(0x0007002a, 0x00100000008);
  static const tab = RaccoonKey(0x0007002b, 0x00100000009, '\t');
  static const space = RaccoonKey(0x0007002c, 0x00000000020, ' ');
  static const delete = RaccoonKey(0x0007004c, 0x0010000007f);
  static const home = RaccoonKey(0x0007004a, 0x00100000306);
  static const end = RaccoonKey(0x0007004d, 0x00100000305);
  static const pageUp = RaccoonKey(0x0007004b, 0x00100000308);
  static const pageDown = RaccoonKey(0x0007004e, 0x00100000307);
  static const arrowRight = RaccoonKey(0x0007004f, 0x00100000303);
  static const arrowLeft = RaccoonKey(0x00070050, 0x00100000302);
  static const arrowDown = RaccoonKey(0x00070051, 0x00100000301);
  static const arrowUp = RaccoonKey(0x00070052, 0x00100000304);
  static const shift = RaccoonKey(0x000700e1, 0x00200000102);
  static const control = RaccoonKey(0x000700e0, 0x00200000100);
  static const alt = RaccoonKey(0x000700e2, 0x00200000104);
  static const meta = RaccoonKey(0x000700e3, 0x00200000106);

  /// The names [RaccoonKey.named] takes, besides single characters.
  static const keyNames = [
    'enter',
    'escape',
    'backspace',
    'tab',
    'space',
    'delete',
    'home',
    'end',
    'page_up',
    'page_down',
    'arrow_left',
    'arrow_right',
    'arrow_up',
    'arrow_down',
    'shift',
    'control',
    'alt',
    'meta',
  ];

  static const _named = {
    'enter': enter,
    'return': enter,
    'escape': escape,
    'esc': escape,
    'backspace': backspace,
    'tab': tab,
    'space': space,
    'delete': delete,
    'home': home,
    'end': end,
    'pageup': pageUp,
    'pagedown': pageDown,
    'arrowleft': arrowLeft,
    'left': arrowLeft,
    'arrowright': arrowRight,
    'right': arrowRight,
    'arrowup': arrowUp,
    'up': arrowUp,
    'arrowdown': arrowDown,
    'down': arrowDown,
    'shift': shift,
    'control': control,
    'ctrl': control,
    'alt': alt,
    'option': alt,
    'meta': meta,
    'cmd': meta,
    'command': meta,
    'super': meta,
  };

  static const _punctuation = {
    '-': 0x0007002d,
    '=': 0x0007002e,
    '[': 0x0007002f,
    ']': 0x00070030,
    r'\': 0x00070031,
    ';': 0x00070033,
    "'": 0x00070034,
    '`': 0x00070035,
    ',': 0x00070036,
    '.': 0x00070037,
    '/': 0x00070038,
    ' ': 0x0007002c,
  };
}
