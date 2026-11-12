import 'package:fixnum/fixnum.dart';
import 'package:raccoon/raccoon.dart';

/// Flutter's `SemanticsAction` values, as [SemanticsNode.actions] carries
/// them, a bit each.
enum SemanticsNodeAction {
  tap(0),
  longPress(1),
  scrollLeft(2),
  scrollRight(3),
  scrollUp(4),
  scrollDown(5),
  increase(6),
  decrease(7),
  showOnScreen(8),
  moveCursorForwardByCharacter(9),
  moveCursorBackwardByCharacter(10),
  setSelection(11),
  copy(12),
  cut(13),
  paste(14),
  didGainAccessibilityFocus(15),
  didLoseAccessibilityFocus(16),
  customAction(17),
  dismiss(18),
  moveCursorForwardByWord(19),
  moveCursorBackwardByWord(20),
  setText(21),
  focus(22),
  scrollToOffset(23),
  expand(24),
  collapse(25);

  const SemanticsNodeAction(this.bit);

  /// The bit's position.
  final int bit;

  /// The action's value on the wire.
  Int64 get value => Int64.ONE << bit;

  /// Whether [node] takes this action now.
  bool isOn(SemanticsNode node) => node.actions & value != Int64.ZERO;

  /// The actions [node] takes, in bit order.
  static List<SemanticsNodeAction> of(SemanticsNode node) =>
      values.where((action) => action.isOn(node)).toList();
}

/// Flutter's `SemanticsFlag` values, as [SemanticsNode.flags] carries them,
/// a bit each: a `has…State` flag says the node has that state at all, and
/// its `is…` partner which way it is.
enum SemanticsNodeFlag {
  hasCheckedState(0),
  isChecked(1),
  isSelected(2),
  isButton(3),
  isTextField(4),
  isFocused(5),
  hasEnabledState(6),
  isEnabled(7),
  isInMutuallyExclusiveGroup(8),
  isHeader(9),
  isObscured(10),
  scopesRoute(11),
  namesRoute(12),
  isHidden(13),
  isImage(14),
  isLiveRegion(15),
  hasToggledState(16),
  isToggled(17),
  hasImplicitScrolling(18),
  isMultiline(19),
  isReadOnly(20),
  isFocusable(21),
  isLink(22),
  isSlider(23),
  isKeyboardKey(24),
  isCheckStateMixed(25),
  hasExpandedState(26),
  isExpanded(27),
  hasSelectedState(28),
  hasRequiredState(29),
  isRequired(30);

  const SemanticsNodeFlag(this.bit);

  /// The bit's position.
  final int bit;

  /// The flag's value on the wire.
  Int64 get value => Int64.ONE << bit;

  /// Whether [node] has this flag.
  bool isOn(SemanticsNode node) => node.flags & value != Int64.ZERO;

  /// The flags [node] has, in bit order.
  static List<SemanticsNodeFlag> of(SemanticsNode node) =>
      values.where((flag) => flag.isOn(node)).toList();
}
