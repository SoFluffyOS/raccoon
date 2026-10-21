import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_view/src/frame_decoder.dart';
import 'package:raccoon_view/src/disconnected_overlay.dart';
import 'package:raccoon_view/src/frame_view.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart'
    show RunnerConnection, ComposingConnection, GpuBufferConnection;
import 'package:raccoon_view/src/host_gpu_textures.dart';
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
  });

  final RunnerConnection connection;

  final bool autofocus;

  /// Overrides the display's device pixel ratio, to preview a denser screen.
  final double? pixelRatio;

  /// Called once when the runner hangs up or the frames end; the view keeps
  /// its last frame under a "Runner disconnected" overlay.
  final VoidCallback? onDisconnected;

  /// The host's native side for GPU buffers, when the connection carries
  /// them; null uses the host's own ([HostGpuTextures.forHost]).
  final HostGpuTextures? gpuTextures;

  @override
  State<RaccoonView> createState() => _RaccoonViewState();
}

class _RaccoonViewState extends State<RaccoonView> {
  final _focus = FocusNode(debugLabel: 'RaccoonView');
  StreamSubscription<rc.GpuBuffers>? _gpuSets;
  HostGpuTextures? _gpu;
  int? _textureId;
  // Whether frames arrive as GPU buffers, and the buffer the texture shows.
  bool _gpuLive = false;
  (int, int)? _shown;
  StreamSubscription<rc.Frame>? _frames;
  StreamSubscription<rc.TextField>? _fields;
  HostedTextInput? _text;
  ui.Image? _image;
  rc.Frame? _pending;
  bool _decoding = false;
  bool _lost = false;
  Size? _sentSize;
  double _pixelRatio = 1;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(RaccoonView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection == widget.connection) return;
    unawaited(_frames?.cancel());
    _unsubscribeText();
    _unsubscribeGpu();
    _sentSize = null;
    _subscribe();
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    _unsubscribeText();
    _unsubscribeGpu();
    _focus.dispose();
    _image?.dispose();
    super.dispose();
  }

  void _subscribe() {
    _subscribeText();
    _subscribeGpu();
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
    final text = HostedTextInput(connection);
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
    _gpu = gpu;
    _gpuSets = connection.gpuBufferSets.listen(
      (set) => unawaited(_onGpuSet(set)),
    );
  }

  Future<void> _onGpuSet(rc.GpuBuffers set) async {
    final gpu = _gpu;
    if (gpu == null) return;
    if (_textureId == null) {
      final id = await gpu.create();
      if (!mounted || id < 0) return;
      _textureId = id;
      await gpu.connect(id, set.socket);
    }
  }

  void _unsubscribeGpu() {
    unawaited(_gpuSets?.cancel());
    _gpuSets = null;
    final connection = widget.connection;
    if (_shown case (
      final generation,
      final index,
    ) when connection is GpuBufferConnection) {
      connection.releaseGpuBuffer(generation, index);
    }
    _shown = null;
    if (_textureId case final id?) unawaited(_gpu?.dispose(id));
    _textureId = null;
    _gpu = null;
    _gpuLive = false;
  }

  void _unsubscribeText() {
    unawaited(_fields?.cancel());
    _fields = null;
    _text?.detach();
    _text = null;
  }

  void _onLost() {
    if (!mounted || _lost) return;
    setState(() => _lost = true);
    widget.onDisconnected?.call();
  }

  void _onFrame(rc.Frame frame) {
    if (frame.inGpuBuffer) {
      unawaited(_showGpuFrame(frame));
      return;
    }
    _pending = frame;
    unawaited(_decodePending());
  }

  /// Names the frame's buffer to the host's texture, then gives the one
  /// shown before back to the runner.
  Future<void> _showGpuFrame(rc.Frame frame) async {
    final gpu = _gpu;
    final id = _textureId;
    final connection = widget.connection;
    if (gpu == null || id == null || connection is! GpuBufferConnection) {
      return;
    }
    final previous = _shown;
    _shown = (frame.gpuGeneration, frame.bufferIndex);
    await gpu.show(id, frame.gpuGeneration, frame.bufferIndex);
    if (previous case (final generation, final index)) {
      connection.releaseGpuBuffer(generation, index);
    }
    if (!mounted) return;
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
        final image = await decodeFrame(frame);
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
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
    final mapped = toRunnerPointer(event, _pixelRatio);
    if (mapped != null) widget.connection.sendPointer(mapped);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final text = _text;
    if (text == null || !text.attached) {
      widget.connection.sendKey(toRunnerKey(event));
      return KeyEventResult.handled;
    }
    // With the host's input method open for the app's field: characters go
    // to both, the method types them and the app sees the key; editing
    // keys are the app's, unless the method is composing, when they are
    // its own.
    if (isEditingKey(event)) {
      if (text.composing) return KeyEventResult.ignored;
      widget.connection.sendKey(toRunnerKey(event));
      return KeyEventResult.handled;
    }
    widget.connection.sendKey(toRunnerKey(event));
    return switch (event.character) {
      final character? when character.isNotEmpty => KeyEventResult.ignored,
      _ => KeyEventResult.handled,
    };
  }

  @override
  Widget build(BuildContext context) {
    final pixelRatio =
        widget.pixelRatio ?? MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isFinite && !size.isEmpty) _sendSize(size, pixelRatio);
        return Focus(
          focusNode: _focus,
          autofocus: widget.autofocus,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerDown: _onPointer,
            onPointerMove: _onPointer,
            onPointerUp: _onPointer,
            onPointerHover: _onPointer,
            onPointerCancel: _onPointer,
            onPointerSignal: _onPointer,
            behavior: HitTestBehavior.opaque,
            child: SizedBox.expand(
              child: Stack(
                // No text direction needed: hosts need not provide one.
                alignment: Alignment.topLeft,
                fit: StackFit.expand,
                children: [
                  switch ((_gpuLive, _textureId)) {
                    // GL textures start at the bottom left; the frame is
                    // drawn the other way up.
                    (true, final id?) => Transform.flip(
                      flipY: true,
                      child: Texture(textureId: id),
                    ),
                    _ => RaccoonFrameView(frame: _image, fit: BoxFit.fill),
                  },
                  if (_lost) const DisconnectedOverlay(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
