import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:raccoon/raccoon.dart' as rc;
import 'package:raccoon_view/src/frame_decoder.dart';
import 'package:raccoon_view/src/frame_view.dart';
import 'package:raccoon_runtime/raccoon_runtime.dart' show RunnerConnection;
import 'package:raccoon_view/src/input_mapping.dart';

/// Shows the app a runner hosts and sends it the view's size, pointer and key
/// events. The runner renders at this widget's size times the device pixel
/// ratio.
class RaccoonView extends StatefulWidget {
  const RaccoonView({
    super.key,
    required this.connection,
    this.autofocus = true,
  });

  final RunnerConnection connection;

  final bool autofocus;

  @override
  State<RaccoonView> createState() => _RaccoonViewState();
}

class _RaccoonViewState extends State<RaccoonView> {
  StreamSubscription<rc.Frame>? _frames;
  ui.Image? _image;
  rc.Frame? _pending;
  bool _decoding = false;
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
    _sentSize = null;
    _subscribe();
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    _image?.dispose();
    super.dispose();
  }

  void _subscribe() {
    _frames = widget.connection.frames.listen(_onFrame);
  }

  void _onFrame(rc.Frame frame) {
    _pending = frame;
    unawaited(_decodePending());
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
    final mapped = toRunnerPointer(event, _pixelRatio);
    if (mapped != null) widget.connection.sendPointer(mapped);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    widget.connection.sendKey(toRunnerKey(event));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size.isFinite && !size.isEmpty) _sendSize(size, pixelRatio);
        return Focus(
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
              child: RaccoonFrameView(frame: _image, fit: BoxFit.fill),
            ),
          ),
        );
      },
    );
  }
}
