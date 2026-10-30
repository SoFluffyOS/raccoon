import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/src/raccoon_device.dart';
import 'package:raccoon_runtime/src/runtime_store.dart';

/// The size each app last had on a host's board, where `raccoon-device run`
/// finds it: `<data>/raccoon/data/<app>/size`, `390x844@3` in logical pixels
/// and a pixel ratio, as `--size` takes it. A run on a device that names no
/// size starts there, instead of 800×600 until the board resizes it.
final class AppSizes {
  const AppSizes(this.directory);

  /// The helper's data directory: `$XDG_DATA_HOME/raccoon/data`, or
  /// `~/.local/share/raccoon/data`.
  factory AppSizes.forHost(Map<String, String> environment) {
    final dataHome = switch (environment['XDG_DATA_HOME']) {
      final home? when home.isNotEmpty => home,
      _ => p.join(RuntimeStore.homeOf(environment), '.local', 'share'),
    };
    return AppSizes(p.join(dataHome, 'raccoon', 'data'));
  }

  /// The directory the size files sit under, a folder per app.
  final String directory;

  File _file(String app) => File(p.join(directory, app, 'size'));

  /// The size saved for [app] (`wonders`, `wonders@tablet`), or null, as
  /// for one that can't be read.
  ({int width, int height, double pixelRatio})? read(String app) {
    final file = _file(app);
    if (!file.existsSync()) return null;
    try {
      return RaccoonDevice.parseSize(file.readAsStringSync());
    } on FileSystemException {
      return null;
    }
  }

  /// Saves [app]'s logical size and pixel ratio for its next run.
  void save(
    String app, {
    required int width,
    required int height,
    required double pixelRatio,
  }) {
    final ratio =
        pixelRatio == pixelRatio.roundToDouble()
            ? '${pixelRatio.round()}'
            : '$pixelRatio';
    _file(app)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${width}x$height@$ratio\n');
  }
}
