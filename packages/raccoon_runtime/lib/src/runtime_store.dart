import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Fetches bytes from [uri]; tests inject one that serves a zip from memory.
typedef Downloader = Future<List<int>> Function(Uri uri);

/// The engine artifacts for one engine revision on one host platform.
final class EngineRuntime {
  const EngineRuntime({
    required this.revision,
    required this.directory,
    required this.platform,
  });

  final String revision;
  final String directory;

  /// The bucket's name for the host, see [RuntimeStore.platformFor].
  final String platform;

  /// The embedder library the runner loads.
  String get engineLibrary =>
      p.join(directory, RuntimeStore.engineLibraryOf(platform));

  String get embedderHeader =>
      p.join(directory, RuntimeStore.embedderHeaderOf(platform));
}

/// Keeps one engine per revision for one host under a cache directory,
/// downloading the prebuilt debug embedder from the Flutter infra bucket when
/// missing.
final class RuntimeStore {
  RuntimeStore({
    required this.cacheDirectory,
    Downloader? download,
    String? platform,
  }) : platform = platform ?? hostPlatform,
       _download = download ?? _httpDownload;

  /// `$XDG_CACHE_HOME/raccoon/engines`, or `~/.cache/raccoon/engines`.
  factory RuntimeStore.forHost(Map<String, String> environment) {
    final cacheHome = switch (environment['XDG_CACHE_HOME']) {
      final dir? when dir.isNotEmpty => dir,
      _ => p.join(environment['HOME'] ?? '', '.cache'),
    };
    return RuntimeStore(
      cacheDirectory: p.join(cacheHome, 'raccoon', 'engines'),
    );
  }

  /// The bucket's name for the host this process runs on.
  static final String hostPlatform = platformFor(
    Platform.operatingSystem,
    Abi.current(),
  );

  /// The bucket's name for [operatingSystem] on [abi]: `linux-x64`,
  /// `linux-arm64`, `windows-x64`, `windows-arm64`, or `darwin` for the one
  /// universal macOS framework.
  static String platformFor(String operatingSystem, Abi abi) {
    final architecture = switch (abi) {
      Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
      Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'x64',
      _ => throw UnsupportedError('no prebuilt embedder for $abi'),
    };
    return switch (operatingSystem) {
      'linux' => 'linux-$architecture',
      'windows' => 'windows-$architecture',
      'macos' => 'darwin',
      _ => throw UnsupportedError('no prebuilt embedder for $operatingSystem'),
    };
  }

  /// The embedder library's path inside a runtime directory.
  static String engineLibraryOf(String platform) => switch (platform) {
    'linux-x64' || 'linux-arm64' => 'libflutter_engine.so',
    'windows-x64' || 'windows-arm64' => 'flutter_engine.dll',
    'darwin' => p.join('FlutterEmbedder.framework', 'FlutterEmbedder'),
    _ => throw ArgumentError.value(platform, 'platform'),
  };

  /// The embedder header's path inside a runtime directory.
  static String embedderHeaderOf(String platform) => switch (platform) {
    'darwin' => p.join(
      'FlutterEmbedder.framework',
      'Headers',
      'FlutterEmbedder.h',
    ),
    _ => 'flutter_embedder.h',
  };

  /// The framework zip unpacks to the framework's contents, so it goes into a
  /// folder of its own; the other zips carry the files at their root.
  static String _extractionRoot(String platform) => switch (platform) {
    'darwin' => 'FlutterEmbedder.framework',
    _ => '',
  };

  final String cacheDirectory;

  /// The bucket's name for the host this store serves, see [platformFor].
  final String platform;

  final Downloader _download;

  /// The bucket path of the embedder zip for [revision] and [platform].
  static Uri artifactUri(String revision, {String? platform}) {
    final name = platform ?? hostPlatform;
    final file = switch (name) {
      'darwin' => 'darwin-x64/FlutterEmbedder.framework.zip',
      _ => '$name/$name-embedder.zip',
    };
    return Uri.parse(
      'https://storage.googleapis.com/flutter_infra_release/flutter/'
      '$revision/$file',
    );
  }

  /// The engine revision an SDK at [sdkRoot] was built with, from its stamp.
  static String? revisionOfSdk(String sdkRoot) {
    for (final candidate in [
      p.join(sdkRoot, 'bin', 'cache', 'engine.stamp'),
      p.join(sdkRoot, 'bin', 'internal', 'engine.version'),
    ]) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      final revision = file.readAsStringSync().trim();
      if (revision.isNotEmpty) return revision;
    }
    return null;
  }

  /// The SDK root for a `flutter` executable, following symlinks.
  static String sdkRootOfFlutter(String flutterExecutable) {
    final resolved = File(flutterExecutable).resolveSymbolicLinksSync();
    return p.dirname(p.dirname(resolved));
  }

  /// The SDK root behind the `flutter` on the PATH, or null without one.
  static String? sdkRootOnPath() {
    final which =
        Process.runSync('which', ['flutter']).stdout.toString().trim();
    if (which.isEmpty) return null;
    return sdkRootOfFlutter(which);
  }

  /// The ICU data file an SDK ships for [platform]. The SDK keeps one macOS
  /// engine directory, `darwin-x64`, for both Mac architectures.
  static String icuDataOfSdk(String sdkRoot, {String? platform}) {
    final directory = switch (platform ?? hostPlatform) {
      'darwin' => 'darwin-x64',
      final name => name,
    };
    return p.join(
      sdkRoot,
      'bin',
      'cache',
      'artifacts',
      'engine',
      directory,
      'icudtl.dat',
    );
  }

  String directoryFor(String revision) =>
      p.join(cacheDirectory, revision, platform);

  /// The installed runtime for [revision], or null.
  EngineRuntime? installed(String revision) {
    final runtime = EngineRuntime(
      revision: revision,
      directory: directoryFor(revision),
      platform: platform,
    );
    if (!File(runtime.engineLibrary).existsSync()) return null;
    return runtime;
  }

  /// Returns the runtime for [revision], downloading and extracting it first
  /// when it is not installed.
  Future<EngineRuntime> ensure(String revision) async {
    if (installed(revision) case final runtime?) return runtime;
    final uri = artifactUri(revision, platform: platform);
    final archive = ZipDecoder().decodeBytes(await _download(uri));
    final directory = Directory(directoryFor(revision));
    final staging = Directory('${directory.path}.partial');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    _extract(archive, p.join(staging.path, _extractionRoot(platform)));
    final library = File(p.join(staging.path, engineLibraryOf(platform)));
    if (!library.existsSync()) {
      staging.deleteSync(recursive: true);
      throw StateError('no ${engineLibraryOf(platform)} in $uri');
    }
    _makeExecutable(library);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    staging.renameSync(directory.path);
    return EngineRuntime(
      revision: revision,
      directory: directory.path,
      platform: platform,
    );
  }

  /// Writes [archive]'s files and symbolic links under [root]; the framework
  /// is mostly links into its `Versions/A`.
  static void _extract(Archive archive, String root) {
    for (final entry in archive.files) {
      final target = p.join(root, entry.name);
      if (entry.symbolicLink case final link? when link.isNotEmpty) {
        Directory(p.dirname(target)).createSync(recursive: true);
        Link(target).createSync(link);
        continue;
      }
      if (!entry.isFile) continue;
      File(target)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entry.content);
    }
  }

  static void _makeExecutable(File file) {
    if (Platform.isWindows) return;
    Process.runSync('chmod', ['755', file.path]);
  }

  static Future<List<int>> _httpDownload(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('${response.statusCode} for $uri', uri: uri);
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }
}
