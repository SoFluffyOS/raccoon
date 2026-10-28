import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:raccoon_view/src/dot_grid.dart';
import 'package:raccoon_view/src/raccoon_view.dart';
import 'package:raccoon_view/src/zoom_control.dart';

/// One device on the board: where its frame sits, how big it is in logical
/// pixels, and at what pixel ratio the app draws.
final class RaccoonBoardFrame {
  const RaccoonBoardFrame({
    required this.name,
    required this.position,
    required this.size,
    required this.pixelRatio,
  });

  /// A frame for a session's name: the device's size and ratio when the
  /// name carries a sized device (`wonders@tablet`), a phone's logical size
  /// at a ratio of 2 otherwise, placed to the right of [existing].
  factory RaccoonBoardFrame.initial(
    String name, {
    Iterable<RaccoonBoardFrame> existing = const [],
  }) {
    final device = RaccoonDevice.forKey(RunnerDiscovery.instanceOf(name));
    final width = device?.width;
    final height = device?.height;
    final size =
        width != null && height != null
            ? Size(width.toDouble(), height.toDouble())
            : const Size(390, 844);
    var x = gap;
    for (final frame in existing) {
      x = math.max(x, frame.position.dx + frame.size.width + gap);
    }
    return RaccoonBoardFrame(
      name: name,
      position: Offset(x, gap),
      size: size,
      pixelRatio: device?.pixelRatio ?? 2,
    );
  }

  /// A frame as [toJson] wrote it.
  factory RaccoonBoardFrame.fromJson(Map<String, Object?> json) =>
      RaccoonBoardFrame(
        name: json['name'] as String,
        position: Offset(
          (json['x'] as num).toDouble(),
          (json['y'] as num).toDouble(),
        ),
        size: Size(
          (json['width'] as num).toDouble(),
          (json['height'] as num).toDouble(),
        ),
        pixelRatio: (json['pixelRatio'] as num).toDouble(),
      );

  /// Space between frames, and from the board's edge, when placed.
  static const gap = 48.0;

  /// No side goes under this when resized.
  static const minSide = 160.0;

  /// The session's app name, `wonders@tablet`, which keys the frame.
  final String name;

  /// The top left of the app, in board units; the title sits above it.
  final Offset position;

  /// The app's logical size.
  final Size size;

  /// The device pixel ratio the app draws at.
  final double pixelRatio;

  /// The device's label: `Raccoon Tablet`, `Raccoon 2`, `Raccoon`.
  String get device {
    final key = RunnerDiscovery.instanceOf(name);
    return RaccoonDevice.forKey(key)?.label ?? 'Raccoon $key';
  }

  /// The project the session runs: `wonders` for `wonders@tablet`.
  String get project => RunnerDiscovery.projectOf(name);

  /// `820 × 1180 · 2x`.
  String get label {
    final ratio =
        pixelRatio == pixelRatio.roundToDouble()
            ? '${pixelRatio.round()}'
            : '$pixelRatio';
    return '${size.width.round()} × ${size.height.round()} · ${ratio}x';
  }

  /// What the frame's title says: `Raccoon Tablet · wonders`. The size has
  /// a chip of its own beside it.
  String get title => '$device · $project';

  /// This frame with the given fields replaced; the name stays.
  RaccoonBoardFrame copyWith({
    Offset? position,
    Size? size,
    double? pixelRatio,
  }) => RaccoonBoardFrame(
    name: name,
    position: position ?? this.position,
    size: size ?? this.size,
    pixelRatio: pixelRatio ?? this.pixelRatio,
  );

  /// The frame as a JSON map, for [RaccoonBoardFrame.fromJson].
  Map<String, Object?> toJson() => {
    'name': name,
    'x': position.dx,
    'y': position.dy,
    'width': size.width,
    'height': size.height,
    'pixelRatio': pixelRatio,
  };
}

/// Where every device sits on the board and how big it is. A host keeps it
/// between launches: [toJson] after [didChange], [replaceAll] with
/// [parse]'s frames on load.
class RaccoonBoardLayout extends ChangeNotifier {
  RaccoonBoardLayout({
    Iterable<RaccoonBoardFrame> frames = const [],
    this.sizes,
  }) {
    for (final frame in frames) {
      _frames[frame.name] = frame;
    }
  }

  /// Where an app's size is kept for its next run, so it starts as the
  /// board left it (#89); null keeps none.
  final AppSizes? sizes;

  final _frames = <String, RaccoonBoardFrame>{};

  /// Every frame, in the order they were made or loaded.
  List<RaccoonBoardFrame> get frames => List.unmodifiable(_frames.values);

  /// The frame for a session, made on first sight next to the others. Safe
  /// during a build: it tells no listener, only [didChange].
  RaccoonBoardFrame frameFor(String name) {
    final existing = _frames[name];
    if (existing != null) return existing;
    final frame = RaccoonBoardFrame.initial(name, existing: _frames.values);
    _frames[name] = frame;
    didChange();
    return frame;
  }

  /// Moves [name]'s frame to [position], in board units.
  void move(String name, Offset position) {
    final frame = _frames[name];
    if (frame == null) return;
    _frames[name] = frame.copyWith(position: position);
    notifyListeners();
    didChange();
  }

  /// Resizes the frame; no side goes under [RaccoonBoardFrame.minSide].
  void resize(String name, Size size) {
    final frame = _frames[name];
    if (frame == null) return;
    final clamped = Size(
      math.max(size.width, RaccoonBoardFrame.minSide),
      math.max(size.height, RaccoonBoardFrame.minSide),
    );
    _frames[name] = frame.copyWith(size: clamped);
    notifyListeners();
    didChange();
  }

  /// Gives the frame a device's size and pixel ratio, as the size menu does,
  /// and keeps it for the app's next run.
  void setSize(String name, Size size, double pixelRatio) {
    final frame = _frames[name];
    if (frame == null) return;
    _frames[name] = frame.copyWith(size: size, pixelRatio: pixelRatio);
    notifyListeners();
    didChange();
    saveSize(name);
  }

  /// Keeps the frame's size for the app's next run, in [sizes]; the board
  /// calls it once a resize ends.
  void saveSize(String name) {
    final frame = _frames[name];
    final sizes = this.sizes;
    if (frame == null || sizes == null) return;
    sizes.save(
      name,
      width: frame.size.width.round(),
      height: frame.size.height.round(),
      pixelRatio: frame.pixelRatio,
    );
  }

  /// Takes a saved layout's frames in place of the current ones.
  void replaceAll(Iterable<RaccoonBoardFrame> frames) {
    _frames.clear();
    for (final frame in frames) {
      _frames[frame.name] = frame;
    }
    notifyListeners();
  }

  /// The layout as a JSON list, for [parse].
  String toJson() =>
      jsonEncode([for (final frame in _frames.values) frame.toJson()]);

  /// The frames of a layout [toJson] wrote; none for text that does not
  /// read as one, since a layout that does not read is no layout.
  static List<RaccoonBoardFrame> parse(String json) {
    try {
      return [
        for (final item in jsonDecode(json) as List)
          RaccoonBoardFrame.fromJson(item as Map<String, Object?>),
      ];
    } on Object {
      return const [];
    }
  }

  /// Called after a frame is made, moved or resized: the moment to save.
  @protected
  void didChange() {}
}

/// A session as the board shows it.
final class RaccoonBoardSession {
  const RaccoonBoardSession({
    required this.name,
    required RunnerConnection this.connection,
    this.onClose,
  }) : status = null;

  /// A frame for a run that has no runner yet, still building: [status]
  /// in place of the app. The session under [name] takes the frame when it
  /// comes.
  const RaccoonBoardSession.starting({
    required this.name,
    required String this.status,
    this.onClose,
  }) : connection = null;

  /// The app name, `wonders@tablet`, which keys its frame in the layout.
  final String name;

  /// The runner the frame shows; null while the run is [status].
  final RunnerConnection? connection;

  /// What a run with no runner yet is doing.
  final String? status;

  /// Asked to shut the session down; without it the frame has no close.
  final VoidCallback? onClose;
}

/// A device size a frame can take, for a host's menu.
final class RaccoonBoardSizeChoice {
  const RaccoonBoardSizeChoice({
    required this.label,
    required this.current,
    required this.pick,
  });

  /// `iPhone 16  393 × 852 · 3x`.
  final String label;

  /// Whether the frame has this size now.
  final bool current;

  /// Gives the frame this size, live and for next time.
  final VoidCallback pick;
}

/// A secondary click on the board, for the host to answer with a menu of
/// its own at [position]: on a frame's title, [session] names it, and on
/// the empty board it is null. The board's own actions come with it.
final class RaccoonBoardMenuRequest {
  const RaccoonBoardMenuRequest({
    required this.session,
    required this.position,
    required this.zoom,
    required this.zoomIn,
    required this.zoomOut,
    required this.resetZoom,
    required this.showAll,
    this.sizes = const [],
    this.close,
  });

  /// The frame's session name, or null on the empty board.
  final String? session;

  /// Where the click was, in global coordinates.
  final Offset position;

  /// The board's zoom, 1 at 100%.
  final double zoom;

  final VoidCallback zoomIn;
  final VoidCallback zoomOut;

  /// Back to 100%, about the middle of the board.
  final VoidCallback resetZoom;

  /// Zooms and pans so every frame is in view.
  final VoidCallback showAll;

  /// For a frame, the device sizes it can take; empty on the board.
  final List<RaccoonBoardSizeChoice> sizes;

  /// For a frame whose session can be shut down.
  final VoidCallback? close;
}

/// Every running device on one canvas: a dot grid that pans and zooms, one
/// frame per session with the device's name and size on it. Drag a frame
/// by its title, or hold Alt (Option on macOS) and grab it anywhere; pull
/// the corner handle to resize, and the app relayouts as it goes. Scroll
/// pans, and so does dragging the empty board. Pinching the empty board
/// zooms about the fingers; with Ctrl (or Cmd) held, a scroll or a drag
/// zooms about the pointer. The zoom control in the corner steps the zoom,
/// and its percent goes back to 100%.
///
/// Each frame's title carries its size; tap it for the devices' sizes. The
/// app resizes as it is picked, and starts at it next time.
///
/// Hosts pass their own ink colour, title style and menu colour, and what
/// to show while nothing runs. A secondary click on a frame's title or on
/// the empty board goes to [onContextMenu], for a menu in the host's look.
class RaccoonBoard extends StatefulWidget {
  const RaccoonBoard({
    super.key,
    required this.sessions,
    required this.layout,
    this.ink = const Color(0xFF808080),
    this.titleStyle,
    this.menuColor = const Color(0xFF242424),
    this.empty,
    this.spacing = 24,
    this.onContextMenu,
  });

  /// The sessions to show, a frame each.
  final List<RaccoonBoardSession> sessions;

  /// Where the frames sit; the board moves and resizes them in it.
  final RaccoonBoardLayout layout;

  /// The colour of the dots, the edges, the titles and the handles, at
  /// their own strengths.
  final Color ink;

  /// The titles' style; the colour comes from [ink] unless given.
  final TextStyle? titleStyle;

  /// The size menu's fill.
  final Color menuColor;

  /// Shown in the middle while there is no session.
  final Widget? empty;

  /// Distance between dots at zoom 1, in the board's pixels.
  final double spacing;

  /// Asked for a menu on a secondary click; without it there is none.
  final ValueChanged<RaccoonBoardMenuRequest>? onContextMenu;

  /// The key of [name]'s title bar, which drags the frame.
  static ValueKey<String> titleKey(String name) =>
      ValueKey('board-title-$name');

  /// The key of [name]'s whole-frame handle, there while Alt is held.
  static ValueKey<String> grabKey(String name) => ValueKey('board-grab-$name');

  /// The key of [name]'s corner resize handle.
  static ValueKey<String> resizeKey(String name) =>
      ValueKey('board-resize-$name');

  /// The key of [name]'s close button.
  static ValueKey<String> closeKey(String name) =>
      ValueKey('board-close-$name');

  /// The key of [name]'s size chip, which opens the size menu.
  static ValueKey<String> sizeKey(String name) => ValueKey('board-size-$name');

  /// The key of the entry for the preset with instance key [device]
  /// (`phone`) in [name]'s size menu.
  static ValueKey<String> sizeOptionKey(String name, String device) =>
      ValueKey('board-size-$name-$device');

  /// The height of the title bar above each frame, in board units.
  static const titleHeight = 28.0;

  /// The side of the corner resize handle, in board units.
  static const handleSize = 16.0;

  /// How far from the origin, in board units, a frame can sit and still be
  /// hit. A box takes no hit outside its own bounds, so the frames' layer
  /// spans this far each way instead of just the viewport.
  static const reach = 100000.0;

  @override
  State<RaccoonBoard> createState() => _RaccoonBoardState();
}

class _RaccoonBoardState extends State<RaccoonBoard> {
  // A resize under way, by frame: the size it began at, and how far the
  // pointer moved since.
  final _resizing = <String, (Size, Offset)>{};

  /// One frame a name: the last session given under it, as when a host
  /// passes a run's starting session with its running one while it hands
  /// over; two of a key would fail the build (#233).
  Iterable<RaccoonBoardSession> get _sessions =>
      {for (final session in widget.sessions) session.name: session}.values;

  Offset _pan = Offset.zero;
  double _zoom = 1;
  double _zoomAtStart = 1;
  Size _viewport = Size.zero;
  bool _altHeld = false;

  /// The session whose size menu is open, if any.
  String? _sizeMenu;

  /// The chip and its menu tap as one: a tap on the chip doesn't close the
  /// menu as a tap outside it, only to open it again.
  static String _sizeGroup(String name) => 'raccoon-board-size-$name';

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    widget.layout.addListener(_changed);
  }

  @override
  void didUpdateWidget(RaccoonBoard old) {
    super.didUpdateWidget(old);
    if (old.layout != widget.layout) {
      old.layout.removeListener(_changed);
      widget.layout.addListener(_changed);
    }
    // A menu goes with its app: one run again under the name opens shut.
    if (_sizeMenu case final name?
        when !widget.sessions.any((session) => session.name == name)) {
      _sizeMenu = null;
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    widget.layout.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool _onKey(KeyEvent event) {
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (alt != _altHeld && mounted) setState(() => _altHeld = alt);
    return false;
  }

  void _onScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (zoomModifierHeld()) {
      _zoomTo(
        _zoom * zoomFactorForScroll(event.scrollDelta.dy),
        event.localPosition,
      );
      return;
    }
    // Over an app the scroll is the app's; around the apps it pans, as on
    // a canvas (#232).
    final at = (event.localPosition - _pan) / _zoom;
    for (final session in _sessions) {
      final frame = widget.layout.frameFor(session.name);
      if ((frame.position & frame.size).contains(at)) return;
    }
    setState(() => _pan -= event.scrollDelta);
  }

  /// Zooms to [next] about [focus], so what is under it stays put.
  void _zoomTo(double next, Offset focus) {
    final zoom = next.clamp(minZoom, maxZoom);
    setState(() {
      _pan = zoomAbout(_pan, _zoom, zoom, focus);
      _zoom = zoom;
    });
  }

  void _onScaleStart(ScaleStartDetails details) => _zoomAtStart = _zoom;

  /// Every frame in view, as large as fits up to 100%, with a margin.
  void _showAll() {
    final frames = [
      for (final session in _sessions) widget.layout.frameFor(session.name),
    ];
    if (frames.isEmpty || _viewport.isEmpty) return;
    var bounds = _frameBounds(frames.first);
    for (final frame in frames.skip(1)) {
      bounds = bounds.expandToInclude(_frameBounds(frame));
    }
    const margin = 48.0;
    final zoom = math
        .min(
          1.0,
          math.min(
            (_viewport.width - 2 * margin) / bounds.width,
            (_viewport.height - 2 * margin) / bounds.height,
          ),
        )
        .clamp(minZoom, maxZoom);
    setState(() {
      _zoom = zoom;
      _pan = _viewport.center(Offset.zero) - bounds.center * zoom;
    });
  }

  static Rect _frameBounds(RaccoonBoardFrame frame) => Rect.fromLTWH(
    frame.position.dx,
    frame.position.dy - RaccoonBoard.titleHeight,
    frame.size.width,
    frame.size.height + RaccoonBoard.titleHeight,
  );

  void _askMenu(Offset position, [RaccoonBoardSession? session]) {
    final ask = widget.onContextMenu;
    if (ask == null) return;
    final center = _viewport.center(Offset.zero);
    final frame = switch (session) {
      final session? => widget.layout.frameFor(session.name),
      null => null,
    };
    ask(
      RaccoonBoardMenuRequest(
        session: session?.name,
        position: position,
        zoom: _zoom,
        // The host's menu may outlive the board (#233).
        zoomIn: () {
          if (mounted) _zoomTo(_zoom * zoomStep, center);
        },
        zoomOut: () {
          if (mounted) _zoomTo(_zoom / zoomStep, center);
        },
        resetZoom: () {
          if (mounted) _zoomTo(1, center);
        },
        showAll: () {
          if (mounted) _showAll();
        },
        sizes: [
          if ((session, frame) case (final session?, final frame?))
            for (final device in RaccoonDevice.presets)
              RaccoonBoardSizeChoice(
                label: _SizeMenu.labelOf(device),
                current: _SizeMenu.isCurrent(frame, device),
                pick:
                    () => widget.layout.setSize(
                      session.name,
                      Size(device.width!.toDouble(), device.height!.toDouble()),
                      device.pixelRatio ?? 1,
                    ),
              ),
        ],
        close: session?.onClose,
      ),
    );
  }

  /// A drag pans, a pinch zooms about the fingers; with the modifier held,
  /// a drag or a trackpad's two-finger scroll zooms.
  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.scale != 1) {
      setState(() => _pan += details.focalPointDelta);
      _zoomTo(_zoomAtStart * details.scale, details.localFocalPoint);
      return;
    }
    if (zoomModifierHeld()) {
      _zoomTo(
        _zoom * zoomFactorForScroll(-details.focalPointDelta.dy),
        details.localFocalPoint,
      );
      return;
    }
    setState(() => _pan += details.focalPointDelta);
  }

  @override
  Widget build(BuildContext context) {
    final controlStyle = (widget.titleStyle ?? const TextStyle(fontSize: 11))
        .copyWith(color: widget.titleStyle?.color ?? widget.ink);
    return ZoomsOnModifiedScroll(
      child: Listener(
        onPointerSignal: _onScroll,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  _viewport = constraints.biggest;
                  return const SizedBox.expand();
                },
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onSecondaryTapUp: (details) => _askMenu(details.globalPosition),
                child: CustomPaint(
                  painter: _GridPainter(
                    ink: widget.ink.withValues(alpha: 0.35),
                    spacing: widget.spacing,
                    pan: _pan,
                    zoom: _zoom,
                  ),
                ),
              ),
              OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 2 * RaccoonBoard.reach,
                maxWidth: 2 * RaccoonBoard.reach,
                minHeight: 2 * RaccoonBoard.reach,
                maxHeight: 2 * RaccoonBoard.reach,
                child: Transform(
                  // Built from the old constructors, so it runs on the oldest
                  // Flutter the package allows.
                  transform:
                      Matrix4.translationValues(_pan.dx, _pan.dy, 0) *
                      Matrix4.diagonal3Values(_zoom, _zoom, 1) *
                      Matrix4.translationValues(
                        -RaccoonBoard.reach,
                        -RaccoonBoard.reach,
                        0,
                      ),
                  child: Stack(
                    children: [
                      for (final session in _sessions) _frame(context, session),
                    ],
                  ),
                ),
              ),
              if (widget.sessions.isEmpty && widget.empty != null)
                Center(child: widget.empty),
              Positioned(
                right: 12,
                bottom: 8,
                child: ZoomControl(
                  zoom: _zoom,
                  style: controlStyle,
                  onZoomOut:
                      () => _zoomTo(
                        _zoom / zoomStep,
                        _viewport.center(Offset.zero),
                      ),
                  onZoomIn:
                      () => _zoomTo(
                        _zoom * zoomStep,
                        _viewport.center(Offset.zero),
                      ),
                  onReset: () => _zoomTo(1, _viewport.center(Offset.zero)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _frame(BuildContext context, RaccoonBoardSession session) {
    final frame = widget.layout.frameFor(session.name);
    final titleStyle = (widget.titleStyle ?? const TextStyle(fontSize: 11))
        .copyWith(color: widget.titleStyle?.color ?? widget.ink);
    // Each step starts from where the frame is now, not where this build
    // put it: steps can land between frames. The deltas come in board
    // units already: the detectors sit under the zoom.
    void moveBy(Offset delta) {
      final current = widget.layout.frameFor(session.name);
      widget.layout.move(session.name, current.position + delta);
    }

    // From the size the drag began at and all it moved since: steps added
    // to a size held at the least lost what was cut, and the corner came
    // off the pointer (#233).
    void resizeBy(Offset delta) {
      final (start, moved) =
          _resizing[session.name] ??
          (widget.layout.frameFor(session.name).size, Offset.zero);
      final total = moved + delta;
      _resizing[session.name] = (start, total);
      widget.layout.resize(
        session.name,
        Size(start.width + total.dx, start.height + total.dy),
      );
    }

    // Keyed by name: a frame keeps its view, focus and texture when one
    // before it closes.
    return Positioned(
      key: ValueKey(session.name),
      left: frame.position.dx + RaccoonBoard.reach,
      top: frame.position.dy - RaccoonBoard.titleHeight + RaccoonBoard.reach,
      width: frame.size.width,
      height: frame.size.height + RaccoonBoard.titleHeight,
      child: Column(
        children: [
          // The title: the device, the project, the size; drag it to move.
          GestureDetector(
            key: RaccoonBoard.titleKey(session.name),
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onPanUpdate: (details) => moveBy(details.delta),
            onSecondaryTapUp:
                (details) => _askMenu(details.globalPosition, session),
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: SizedBox(
                height: RaccoonBoard.titleHeight,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        frame.title,
                        style: titleStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TapRegion(
                      groupId: _sizeGroup(session.name),
                      child: GestureDetector(
                        key: RaccoonBoard.sizeKey(session.name),
                        onTap:
                            () => setState(
                              () =>
                                  _sizeMenu = switch (_sizeMenu ==
                                      session.name) {
                                    true => null,
                                    false => session.name,
                                  },
                            ),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            // At most most of the title: a frame made as
                            // narrow as it goes overflowed by its size
                            // (#233).
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: frame.size.width * 0.6,
                              ),
                              child: Text(
                                '${frame.label} ▾',
                                style: titleStyle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (session.onClose case final onClose?)
                      GestureDetector(
                        key: RaccoonBoard.closeKey(session.name),
                        onTap: onClose,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: CustomPaint(
                              size: const Size.square(10),
                              painter: _CrossPainter(widget.ink),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: widget.ink.withValues(alpha: 0.6),
                    ),
                  ),
                  child: switch (session.connection) {
                    final connection? => RaccoonView(
                      connection: connection,
                      pixelRatio: frame.pixelRatio,
                    ),
                    null => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          session.status ?? '',
                          style: titleStyle,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  },
                ),
                // Alt held: the whole frame is a handle, the app gets nothing.
                if (_altHeld)
                  Positioned.fill(
                    child: GestureDetector(
                      key: RaccoonBoard.grabKey(session.name),
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onPanUpdate: (details) => moveBy(details.delta),
                      child: const MouseRegion(cursor: SystemMouseCursors.grab),
                    ),
                  ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    key: RaccoonBoard.resizeKey(session.name),
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onPanStart: (_) => _resizing.remove(session.name),
                    onPanUpdate: (details) => resizeBy(details.delta),
                    onPanEnd: (_) {
                      _resizing.remove(session.name);
                      widget.layout.saveSize(session.name);
                    },
                    onPanCancel: () => _resizing.remove(session.name),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeDownRight,
                      child: CustomPaint(
                        size: const Size.square(RaccoonBoard.handleSize),
                        painter: _HandlePainter(widget.ink),
                      ),
                    ),
                  ),
                ),
                if (_sizeMenu == session.name)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: TapRegion(
                      groupId: _sizeGroup(session.name),
                      onTapOutside: (_) => setState(() => _sizeMenu = null),
                      child: _SizeMenu(
                        name: session.name,
                        current: frame,
                        color: widget.menuColor,
                        style: titleStyle,
                        onPick: (device) {
                          setState(() => _sizeMenu = null);
                          widget.layout.setSize(
                            session.name,
                            Size(
                              device.width!.toDouble(),
                              device.height!.toDouble(),
                            ),
                            device.pixelRatio ?? 1,
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The devices' sizes for a frame, the current one marked.
class _SizeMenu extends StatelessWidget {
  const _SizeMenu({
    required this.name,
    required this.current,
    required this.color,
    required this.style,
    required this.onPick,
  });

  final String name;
  final RaccoonBoardFrame current;
  final Color color;
  final TextStyle style;
  final ValueChanged<RaccoonDevice> onPick;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final device in RaccoonDevice.presets)
                GestureDetector(
                  key: RaccoonBoard.sizeOptionKey(name, device.key),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onPick(device),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Text(
                        '${isCurrent(current, device) ? '✓ ' : '   '}'
                        '${labelOf(device)}',
                        style: style,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// `iPhone 16  393 × 852 · 3x`.
  static String labelOf(RaccoonDevice device) =>
      '${device.label.replaceFirst('Raccoon ', '')}  '
      '${device.width} × ${device.height} · '
      '${_ratio(device.pixelRatio ?? 1)}x';

  static bool isCurrent(RaccoonBoardFrame frame, RaccoonDevice device) =>
      frame.size.width == device.width &&
      frame.size.height == device.height &&
      frame.pixelRatio == (device.pixelRatio ?? 1);

  static String _ratio(double ratio) =>
      ratio == ratio.roundToDouble() ? '${ratio.round()}' : '$ratio';
}

/// The grid in screen space: it moves with the pan and spreads with the
/// zoom, so the board reads as one surface.
class _GridPainter extends CustomPainter {
  const _GridPainter({
    required this.ink,
    required this.spacing,
    required this.pan,
    required this.zoom,
  });

  final Color ink;
  final double spacing;
  final Offset pan;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final step = spacing * zoom;
    if (step < 6) return;
    paintDotGrid(canvas, size, pan, step, ink);
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.pan != pan ||
      old.zoom != zoom ||
      old.ink != ink ||
      old.spacing != spacing;
}

/// Two short diagonals in the corner: the usual sign for a resize grip.
class _HandlePainter extends CustomPainter {
  const _HandlePainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = ink
          ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(size.width - 2, 6),
      Offset(6, size.height - 2),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - 2, 11),
      Offset(11, size.height - 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HandlePainter old) => old.ink != ink;
}

/// A small ×, so the close needs no icon font.
class _CrossPainter extends CustomPainter {
  const _CrossPainter(this.ink);

  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = ink
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.ink != ink;
}
