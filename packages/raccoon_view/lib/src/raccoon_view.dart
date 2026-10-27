import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerExitEvent;
import 'package:flutter/rendering.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_view/src/frame_decoder.dart';
import 'package:raccoon_view/src/disconnected_overlay.dart';
import 'package:raccoon_view/src/frame_view.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart'
    show
        RunnerConnection,
        CaptureConnection,
        ComposingConnection,
        GpuBufferConnection,
        ChannelConnection;
import 'package:raccoon_view/src/host_gpu_textures.dart';
import 'package:raccoon_view/src/hosted_mouse_cursor.dart';
import 'package:raccoon_view/src/hosted_text_input.dart';
import 'package:raccoon_view/src/input_mapping.dart';

/// Shows the app a runner hosts and sends it the view's size, pointer and key
/// events. The runner renders at this widget's size times the device pixel
/// ratio, [pixelRatio] when given, else the display's.
class RaccoonView extends StatefulWidget {
  const RaccoonView({
    super.key,
    required this.connection,
    this.autofocus = true,
    this.pixelRatio,
    this.onDisconnected,
    this.gpuTextures,
    this.touch = false,
  });

  /// The runner whose app to show. A [ComposingConnection] that composes
  /// also gets the host's input method, a [GpuBufferConnection] that asked
  /// for GPU buffers is shown through a texture, and a [ChannelConnection]
  /// serves the app's mouse cursor.
  final RunnerConnection connection;

  /// Whether the view takes the keys when first built, if nothing else
  /// has focus; a click into the app takes them either way.
  final bool autofocus;

  /// Overrides the display's device pixel ratio, to preview a denser screen.
  final double? pixelRatio;

  /// Called once when the runner hangs up or the frames end; the view keeps
  /// its last frame under a "Runner disconnected" overlay.
  final VoidCallback? onDisconnected;

  /// The host's native side for GPU buffers, when the connection carries
  /// them; null uses the host's own ([HostGpuTextures.forHost]).
  final HostGpuTextures? gpuTextures;

  /// Sends the mouse as a finger, as a phone app expects (#207): a list
  /// drags and flings, and gestures tuned for touch behave as on a phone.
  final bool touch;

  @override
  State<RaccoonView> createState() => _RaccoonViewState();
}

class _RaccoonViewState extends State<RaccoonView> {
  final _focus = FocusNode(debugLabel: 'RaccoonView');
  StreamSubscription<rc.GpuBuffers>? _gpuSets;
  HostGpuTextures? _gpu;
  int? _textureId;
  bool _creatingTexture = false;
  // Whether frames arrive as GPU buffers, and the buffer the texture shows.
  bool _gpuLive = false;

  /// The view that shows each connection's ring (#205).
  static final _ringHolders = Expando<Object>('raccoon view ring holders');

  /// The views that wait on each connection's ring, first come first: the
  /// first still there takes it when its holder goes (#206).
  static final _ringWaiters = Expando<List<_RaccoonViewState>>(
    'raccoon view ring waiters',
  );

  /// Whether this view asked its connection for pixel frames, another view
  /// holding its ring.
  bool _askedPixels = false;
  // When the last GPU frame came; pixel frames are dropped while the ring
  // is live, and the ring counts as live for this long after that.
  DateTime? _lastGpuFrame;
  static const _ringQuiet = Duration(milliseconds: 500);
  // Whether the host gives buffers back to the runner itself.
  bool _hostReleases = false;
  (int, int)? _shown;
  // The latest GPU frame that came before the texture was ready to show it:
  // shown once it is, since a still app sends no other.
  rc.Frame? _unshownGpu;
  StreamSubscription<rc.Frame>? _frames;
  StreamSubscription<rc.TextField>? _fields;
  HostedTextInput? _text;
  HostedMouseCursor? _mouseCursor;
  MouseCursor _cursor = MouseCursor.defer;
  // The latest read-back frame. A frame rebuilds only the image that shows
  // it, not the view around it, and repaints nothing beside the view (#107).
  final _image = ValueNotifier<ui.Image?>(null);
  rc.Frame? _pending;
  bool _decoding = false;
  bool _lost = false;
  Size? _sentSize;
  double _pixelRatio = 1;

  /// Whether the runner has heard of the mouse since it last left: the
  /// engine takes a mouse's leaving only from one it knows.
  bool _mouseIn = false;

  /// Counts the GPU subscriptions dropped, so a texture made for one since
  /// dropped is told apart.
  var _gpuGeneration = 0;

  /// The keys the runner has seen go down and not yet up. An up or repeat
  /// it never saw the down of is not sent, and what is held when focus
  /// leaves is let go (#133).
  final _pressed = <PhysicalKeyboardKey, LogicalKeyboardKey>{};

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _subscribe();
  }

  @override
  void didUpdateWidget(RaccoonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection == widget.connection) return;
    unawaited(_frames?.cancel());
    _unsubscribeText();
    // The old runner's buffers go back to it, not to the new one (#143).
    _unsubscribeGpu(oldWidget.connection);
    _unsubscribeCursor();
    _sentSize = null;
    _mouseIn = false;
    // The new runner saw none of them go down.
    _pressed.clear();
    _subscribe();
  }

  @override
  void dispose() {
    _releaseKeys();
    unawaited(_frames?.cancel());
    _unsubscribeText();
    _unsubscribeGpu(widget.connection);
    _unsubscribeCursor();
    _focus.dispose();
    _image.value?.dispose();
    _image.dispose();
    super.dispose();
  }

  void _subscribe() {
    _subscribeText();
    _subscribeGpu();
    _subscribeCursor();
    _lost = false;
    _frames = widget.connection.frames.listen(
      _onFrame,
      onError: (Object _) => _onLost(),
      onDone: _onLost,
    );
  }

  /// A connection that composes mirrors the app's active field in the
  /// host's input method.
  void _subscribeText() {
    final connection = widget.connection;
    if (connection is! ComposingConnection) return;
    if (!connection.composes) return;
    final text = HostedTextInput(connection, _focus);
    _text = text;
    _fields = connection.textFields.listen(text.field);
  }

  /// A connection that carries GPU buffers shows them through the host's
  /// texture; the first set names the socket the native side reads.
  void _subscribeGpu() {
    final connection = widget.connection;
    if (connection is! GpuBufferConnection) return;
    if (!connection.gpuBuffers) return;
    final gpu = widget.gpuTextures ?? HostGpuTextures.forHost();
    if (gpu == null) return;
    // The runner serves a connection's ring to one view at a time; another
    // view of it takes pixel frames meanwhile, which the first then shows
    // too (#205).
    if (_ringHolders[connection] case final holder?
        when !identical(holder, this)) {
      if (connection case final CaptureConnection capture) {
        capture.wantPixels(true);
        _askedPixels = true;
        (_ringWaiters[connection] ??= []).add(this);
      }
      return;
    }
    _ringHolders[connection] = this;
    _gpu = gpu;
    _gpuSets = connection.gpuBufferSets.listen(
      (set) => unawaited(_onGpuSet(set)),
    );
  }

  Future<void> _onGpuSet(rc.GpuBuffers set) async {
    final gpu = _gpu;
    if (gpu == null || _creatingTexture) return;
    if (_textureId == null) {
      _creatingTexture = true;
      // A texture made for a connection since swapped, or for a view since
      // gone, is let go: the new connection makes its own (#133).
      final generation = _gpuGeneration;
      bool current() => mounted && generation == _gpuGeneration;
      var id = -1;
      try {
        id = await gpu.create();
        if (id < 0 || !current()) {
          if (id >= 0) unawaited(gpu.dispose(id));
          if (current()) _creatingTexture = false;
          return;
        }
        final releases = await gpu.connect(id, set.socket);
        if (!current()) {
          unawaited(gpu.dispose(id));
          return;
        }
        // Frames name the texture only once the host reads the socket, so
        // the host and the view agree on who gives each buffer back.
        _textureId = id;
        _hostReleases = releases;
        _creatingTexture = false;
      } on Object {
        // The next set tries again.
        if (id >= 0) unawaited(gpu.dispose(id));
        if (current()) _creatingTexture = false;
        return;
      }
    }
    if (_unshownGpu case final frame?) {
      _unshownGpu = null;
      await _showGpuFrame(frame);
    }
  }

  /// Lets go of the GPU texture and gives [connection], the one the
  /// buffers came from, back what the view still holds.
  void _unsubscribeGpu(RunnerConnection connection) {
    _ringWaiters[connection]?.remove(this);
    final heldRing = identical(_ringHolders[connection], this);
    if (heldRing) _ringHolders[connection] = null;
    if (_askedPixels && connection is CaptureConnection) {
      connection.wantPixels(false);
    }
    _askedPixels = false;
    if (heldRing) _passRing(connection);
    _gpuGeneration++;
    unawaited(_gpuSets?.cancel());
    _gpuSets = null;
    if (connection is GpuBufferConnection) {
      if (_shown case (final generation, final index) when !_hostReleases) {
        connection.releaseGpuBuffer(generation, index);
      }
      // Never named to the host, so the host never gives it back.
      if (_unshownGpu case final frame?) {
        connection.releaseGpuBuffer(frame.gpuGeneration, frame.bufferIndex);
      }
    }
    _unshownGpu = null;
    _shown = null;
    _lastGpuFrame = null;
    _hostReleases = false;
    if (_textureId case final id?) unawaited(_gpu?.dispose(id));
    _textureId = null;
    _creatingTexture = false;
    _gpu = null;
    _gpuLive = false;
  }

  /// The ring [connection]'s holder let go of goes to the first view still
  /// waiting on it, which drops its ask for pixels (#206).
  static void _passRing(RunnerConnection connection) {
    final waiters = _ringWaiters[connection];
    while (waiters != null && waiters.isNotEmpty) {
      final next = waiters.removeAt(0);
      if (!next.mounted || !identical(next.widget.connection, connection)) {
        continue;
      }
      if (next._askedPixels && connection is CaptureConnection) {
        connection.wantPixels(false);
      }
      next._askedPixels = false;
      next._subscribeGpu();
      return;
    }
  }

  /// A connection that can serve the app's channels takes its mouse cursor
  /// too; until the app asks for one the view defers to what is around it.
  void _subscribeCursor() {
    final connection = widget.connection;
    if (connection is! ChannelConnection) return;
    _mouseCursor = HostedMouseCursor(connection, (cursor) {
      if (mounted && cursor != _cursor) setState(() => _cursor = cursor);
    });
  }

  void _unsubscribeCursor() {
    _mouseCursor?.detach();
    _mouseCursor = null;
    _cursor = MouseCursor.defer;
  }

  void _unsubscribeText() {
    unawaited(_fields?.cancel());
    _fields = null;
    _text?.dispose();
    _text = null;
  }

  void _onLost() {
    if (!mounted || _lost) return;
    // The app's cursor went with it.
    setState(() {
      _lost = true;
      _cursor = MouseCursor.defer;
    });
    widget.onDisconnected?.call();
  }

  void _onFrame(rc.Frame frame) {
    if (frame.inGpuBuffer) {
      _lastGpuFrame = DateTime.now();
      unawaited(_showGpuFrame(frame));
      return;
    }
    // While the texture is live the host draws the ring, not pixels: a
    // pixel frame is the runner going by readback for one frame, and
    // decoding it would be for nothing. A ring quiet for a while is given
    // up on, so an app whose ring died still shows; one a capture traded
    // for pixel frames shows them at once (#204).
    if (_gpuLive && !_ringQuietNow && !_capturing) return;
    _pending = frame;
    unawaited(_decodePending());
  }

  /// Whether the client traded its ring for pixel frames, for a capture.
  bool get _capturing => switch (widget.connection) {
    final CaptureConnection connection => connection.pixelsWanted,
    _ => false,
  };

  bool get _ringQuietNow => switch (_lastGpuFrame) {
    final last? => DateTime.now().difference(last) >= _ringQuiet,
    null => true,
  };

  /// Names the frame's buffer to the host's texture, then gives the one
  /// shown before back to the runner, unless the host does that itself once
  /// it is done drawing it. Before the texture is ready, the frame waits
  /// for it, and the one waiting before goes back.
  Future<void> _showGpuFrame(rc.Frame frame) async {
    final gpu = _gpu;
    final id = _textureId;
    final connection = widget.connection;
    if (connection is! GpuBufferConnection) return;
    if (gpu == null || id == null) {
      if (_unshownGpu case final waiting?) {
        connection.releaseGpuBuffer(waiting.gpuGeneration, waiting.bufferIndex);
      }
      _unshownGpu = frame;
      return;
    }
    final previous = _shown;
    final shown = (frame.gpuGeneration, frame.bufferIndex);
    _shown = shown;
    final generation = _gpuGeneration;
    await gpu.show(id, frame.gpuGeneration, frame.bufferIndex);
    // The buffer shown before, unless it is this one again: a view made
    // anew on a connection first shows the last frame, which the view
    // before may have given back, and the runner may hand it out again.
    // Given back twice, the buffer on screen could be drawn into (#133).
    if (previous case (
      final generation,
      final index,
    ) when !_hostReleases && previous != shown) {
      connection.releaseGpuBuffer(generation, index);
    }
    // A show that ends after a swap says nothing of the new connection.
    if (!mounted || generation != _gpuGeneration) return;
    if (!_gpuLive) setState(() => _gpuLive = true);
  }

  Future<void> _decodePending() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (true) {
        final frame = _pending;
        if (frame == null) return;
        _pending = null;
        final ui.Image image;
        try {
          image = await decodeFrame(frame);
        } on Object {
          // A frame that can't be shown is skipped; the next one may be.
          continue;
        }
        if (!mounted) {
          image.dispose();
          return;
        }
        final previous = _image.value;
        _image.value = image;
        previous?.dispose();
        // The texture goes only once a frame has taken its place: before,
        // the view showed what it had decoded before the ring came, or
        // nothing, until the next frame (#143).
        if (_gpuLive && (_ringQuietNow || _capturing)) {
          setState(() => _gpuLive = false);
        }
      }
    } finally {
      _decoding = false;
    }
  }

  void _sendSize(Size size, double pixelRatio) {
    if (_sentSize == size && _pixelRatio == pixelRatio) return;
    _sentSize = size;
    _pixelRatio = pixelRatio;
    widget.connection.resize(
      (size.width * pixelRatio).round(),
      (size.height * pixelRatio).round(),
      pixelRatio,
    );
  }

  void _onPointer(PointerEvent event) {
    // A click into the app is a click into the app: the keys follow it.
    if (event is PointerDownEvent && !_focus.hasFocus) _focus.requestFocus();
    final mapped = toRunnerPointer(
      event,
      _pixelRatio,
      mouseAsTouch: widget.touch,
    );
    if (mapped == null) return;
    if (event.kind == PointerDeviceKind.mouse) _mouseIn = true;
    widget.connection.sendPointer(mapped);
    // A finger lifted is gone, as a touchscreen says: each press is a
    // pointer of its own, and the engine would keep every one (#207).
    final lifted = event is PointerUpEvent || event is PointerCancelEvent;
    if (lifted && mapped.device == rc.PointerDevice.POINTER_DEVICE_TOUCH) {
      widget.connection.sendPointer(
        mapped.deepCopy()..phase = rc.PointerPhase.POINTER_PHASE_REMOVE,
      );
    }
  }

  /// The mouse left the view; not while it drags, which goes on outside.
  void _onExit(PointerExitEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (!_mouseIn || event.buttons != 0) return;
    _onPointer(event);
    _mouseIn = false;
  }

  void _onFocus() {
    if (!_focus.hasFocus) _releaseKeys();
  }

  /// Lets go of every key the runner still holds down: their ups go to
  /// whatever took focus, or nowhere.
  void _releaseKeys() {
    final now = Int64(DateTime.now().microsecondsSinceEpoch);
    for (final MapEntry(key: physical, value: logical) in _pressed.entries) {
      widget.connection.sendKey(
        rc.KeyEvent(
          kind: rc.KeyKind.KEY_KIND_UP,
          physical: Int64(physical.usbHidUsage),
          logical: Int64(logical.keyId),
          timestampMicros: now,
          synthesized: true,
        ),
      );
    }
    _pressed.clear();
  }

  /// Sends [event] unless it is an up or repeat of a key the runner never
  /// saw go down; tells whether it went.
  bool _sendKey(KeyEvent event) {
    switch (event) {
      case KeyDownEvent():
        _pressed[event.physicalKey] = event.logicalKey;
      case KeyUpEvent():
        if (_pressed.remove(event.physicalKey) == null) return false;
      case KeyRepeatEvent():
        if (!_pressed.containsKey(event.physicalKey)) return false;
    }
    widget.connection.sendKey(toRunnerKey(event));
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final text = _text;
    if (text == null || !text.attached) {
      _sendKey(event);
      return KeyEventResult.handled;
    }
    // With the host's input method open for the app's field: characters go
    // to both, the method types them and the app sees the key; editing
    // keys are the app's, unless the method is composing, when they are
    // its own.
    if (isEditingKey(event)) {
      // The up of a key the app saw go down is the app's, composing or not.
      if (text.composing && !_pressed.containsKey(event.physicalKey)) {
        return KeyEventResult.ignored;
      }
      // The up of a key whose down the method took is the method's too.
      if (!_sendKey(event)) return KeyEventResult.ignored;
      return KeyEventResult.handled;
    }
    _sendKey(event);
    return switch (event.character) {
      final character? when character.isNotEmpty => KeyEventResult.ignored,
      _ => KeyEventResult.handled,
    };
  }

  @override
  Widget build(BuildContext context) {
    final pixelRatio =
        widget.pixelRatio ?? MediaQuery.devicePixelRatioOf(context);
    // The size goes to the runner from layout. A LayoutBuilder would lay the
    // view out again for every frame, and repaint what is around it (#107).
    return _SizeReport(
      connection: widget.connection,
      pixelRatio: pixelRatio,
      onSize: _sendSize,
      child: Focus(
        focusNode: _focus,
        autofocus: widget.autofocus,
        onKeyEvent: _onKey,
        child: MouseRegion(
          // What the app asks for (see HostedMouseCursor).
          cursor: _cursor,
          onExit: _onExit,
          child: Listener(
            onPointerDown: _onPointer,
            onPointerMove: _onPointer,
            onPointerUp: _onPointer,
            onPointerHover: _onPointer,
            onPointerCancel: _onPointer,
            onPointerSignal: _onPointer,
            onPointerPanZoomStart: _onPointer,
            onPointerPanZoomUpdate: _onPointer,
            onPointerPanZoomEnd: _onPointer,
            behavior: HitTestBehavior.opaque,
            child: SizedBox.expand(
              child: Stack(
                // No text direction needed: hosts need not provide one.
                alignment: Alignment.topLeft,
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: switch ((_gpuLive, _textureId, _gpu)) {
                      // A texture that starts at the bottom left (GL's do)
                      // is drawn the other way up.
                      (true, final id?, final gpu?) => Transform.flip(
                        flipY: gpu.bottomUp,
                        child: Texture(textureId: id),
                      ),
                      _ => ValueListenableBuilder(
                        valueListenable: _image,
                        builder:
                            (context, image, _) => RaccoonFrameView(
                              frame: image,
                              fit: BoxFit.fill,
                            ),
                      ),
                    },
                  ),
                  if (_lost) const DisconnectedOverlay(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports the biggest size its constraints allow, when finite and not
/// empty, after a layout; lays out again only when the constraints, the
/// pixel ratio or the connection change. A new connection is a runner that
/// has not heard the size yet.
class _SizeReport extends SingleChildRenderObjectWidget {
  const _SizeReport({
    required this.connection,
    required this.pixelRatio,
    required this.onSize,
    super.child,
  });

  final RunnerConnection connection;
  final double pixelRatio;
  final void Function(Size size, double pixelRatio) onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReport(connection, pixelRatio, onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeReport renderObject,
  ) {
    renderObject
      ..connection = connection
      ..pixelRatio = pixelRatio
      ..onSize = onSize;
  }
}

class _RenderSizeReport extends RenderProxyBox {
  _RenderSizeReport(this._connection, this._pixelRatio, this.onSize);

  RunnerConnection _connection;
  double _pixelRatio;
  void Function(Size size, double pixelRatio) onSize;

  set connection(RunnerConnection value) {
    if (identical(value, _connection)) return;
    _connection = value;
    markNeedsLayout();
  }

  set pixelRatio(double value) {
    if (value == _pixelRatio) return;
    _pixelRatio = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    final biggest = constraints.biggest;
    if (biggest.isFinite && !biggest.isEmpty) onSize(biggest, _pixelRatio);
  }
}
