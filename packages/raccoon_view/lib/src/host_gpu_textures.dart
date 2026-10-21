import 'dart:io';

import 'package:flutter/services.dart';

/// The host's native side for GPU buffers: a Flutter texture fed from the
/// runner's GPU socket. See `linux/raccoon_view_plugin.cc`.
abstract interface class HostGpuTextures {
  /// The implementation for this host, null where there is none.
  static HostGpuTextures? forHost() => switch (Platform.isLinux) {
    true => const MethodChannelGpuTextures(),
    false => null,
  };

  /// Registers a texture; returns its id for a [Texture] widget.
  Future<int> create();

  /// Takes the buffers' descriptors from the runner's GPU socket.
  Future<void> connect(int textureId, String socket);

  /// Shows buffer [index] of [generation] as the texture's next frame.
  Future<void> show(int textureId, int generation, int index);

  Future<void> dispose(int textureId);
}

/// [HostGpuTextures] over the plugin's method channel.
final class MethodChannelGpuTextures implements HostGpuTextures {
  const MethodChannelGpuTextures();

  static const channel = MethodChannel('raccoon_view/gpu');

  @override
  Future<int> create() async => await channel.invokeMethod<int>('create') ?? -1;

  @override
  Future<void> connect(int textureId, String socket) =>
      channel.invokeMethod<void>('connect', {
        'textureId': textureId,
        'socket': socket,
      });

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
