import 'dart:io';

import 'package:flutter/services.dart';

/// The host's native side for GPU buffers: a Flutter texture fed from the
/// runner's GPU socket. See `linux/raccoon_view_plugin.cc`,
/// `macos/raccoon_view/Sources/raccoon_view/RaccoonViewPlugin.mm` and
/// `windows/raccoon_view_plugin.cpp`.
abstract interface class HostGpuTextures {
  /// The implementation for this host, null where there is none.
  static HostGpuTextures? forHost() => switch (Platform.operatingSystem) {
    // GL textures start at the bottom left; Metal's and D3D11's at the top.
    'linux' => const MethodChannelGpuTextures(bottomUp: true),
    'macos' || 'windows' => const MethodChannelGpuTextures(bottomUp: false),
    _ => null,
  };

  /// Whether the texture's first row is the frame's last, as a GL texture's
  /// is: the view then draws it the other way up.
  bool get bottomUp;

  /// Registers a texture; returns its id for a [Texture] widget.
  Future<int> create();

  /// Takes the buffers' descriptors from the runner's GPU socket. True when
  /// the host gives each buffer back to the runner itself once it is done
  /// drawing it; false when the view has to, after naming the next.
  Future<bool> connect(int textureId, String socket);

  /// Shows buffer [index] of [generation] as the texture's next frame.
  Future<void> show(int textureId, int generation, int index);

  /// Unregisters the texture [textureId].
  Future<void> dispose(int textureId);
}

/// [HostGpuTextures] over the plugin's method channel.
final class MethodChannelGpuTextures implements HostGpuTextures {
  const MethodChannelGpuTextures({required this.bottomUp});

  /// The plugin's channel, `raccoon_view/gpu`.
  static const channel = MethodChannel('raccoon_view/gpu');

  // Once an isolate, before its first texture: a host's hot restart keeps
  // the native plugin and the textures the old views made, each holding its
  // runner's GPU socket, which takes one client; they go (raccoon#239). A
  // plugin that predates it answers not implemented.
  static Future<void>? _reset;

  static Future<void> _resetOnce() =>
      _reset ??= channel.invokeMethod<void>('reset').catchError((Object _) {});

  @override
  final bool bottomUp;

  @override
  Future<int> create() async {
    await _resetOnce();
    return await channel.invokeMethod<int>('create') ?? -1;
  }

  @override
  Future<bool> connect(int textureId, String socket) async =>
      await channel.invokeMethod<bool>('connect', {
        'textureId': textureId,
        'socket': socket,
      }) ??
      false;

  @override
  Future<void> show(int textureId, int generation, int index) =>
      channel.invokeMethod<void>('show', {
        'textureId': textureId,
        'generation': generation,
        'index': index,
      });

  @override
  Future<void> dispose(int textureId) =>
      channel.invokeMethod<void>('dispose', {'textureId': textureId});
}
