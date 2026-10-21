import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Fetches bytes from [uri]; tests inject one that serves a zip from memory.
typedef Downloader = Future<List<int>> Function(Uri uri);

/// The engine artifacts for one engine revision on one host platform.
final class EngineRuntime {
  const EngineRuntime({required this.revision, required this.directory});

  final String revision;
  final String directory;

  String get engineLibrary => p.join(directory, 'libflutter_engine.so');
  String get embedderHeader => p.join(directory, 'flutter_embedder.h');
}

/// Keeps one engine per revision under a cache directory, downloading the
/// prebuilt debug embedder from the Flutter infra bucket when missing.
final class RuntimeStore {
  RuntimeStore({required this.cacheDirectory, Downloader? download})
    : _download = download ?? _httpDownload;

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

  static const String defaultPlatform = 'linux-x64';

  final String cacheDirectory;
  final Downloader _download;

  /// The bucket path of the embedder zip for [revision] and [platform].
  static Uri artifactUri(
    String revision, {
    String platform = defaultPlatform,
  }) => Uri.parse(
    'https://storage.googleapis.com/flutter_infra_release/flutter/'
    '$revision/$platform/$platform-embedder.zip',
  );

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

  /// The ICU data file an SDK ships for Linux.
  static String icuDataOfSdk(String sdkRoot) => p.join(
    sdkRoot,
    'bin',
    'cache',
    'artifacts',
    'engine',
    'linux-x64',
    'icudtl.dat',
  );

  String directoryFor(String revision, {String platform = defaultPlatform}) =>
      p.join(cacheDirectory, revision, platform);

  /// The installed runtime for [revision], or null.
  EngineRuntime? installed(
    String revision, {
    String platform = defaultPlatform,
  }) {
    final runtime = EngineRuntime(
      revision: revision,
      directory: directoryFor(revision, platform: platform),
    );
    if (!File(runtime.engineLibrary).existsSync()) return null;
    return runtime;
  }

  /// Returns the runtime for [revision], downloading and extracting it first
  /// when it is not installed.
  Future<EngineRuntime> ensure(
    String revision, {
    String platform = defaultPlatform,
  }) async {
    if (installed(revision, platform: platform) case final runtime?) {
      return runtime;
    }
    final bytes = await _download(artifactUri(revision, platform: platform));
    final archive = ZipDecoder().decodeBytes(bytes);
    final directory = Directory(directoryFor(revision, platform: platform));
    final staging = Directory('${directory.path}.partial');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final target = File(p.join(staging.path, entry.name));
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(entry.content as List<int>);
    }
    final library = File(p.join(staging.path, 'libflutter_engine.so'));
    if (!library.existsSync()) {
      staging.deleteSync(recursive: true);
      throw StateError(
        'no libflutter_engine.so in ${artifactUri(revision, platform: platform)}',
      );
    }
    _makeExecutable(library);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
    staging.renameSync(directory.path);
    return EngineRuntime(revision: revision, directory: directory.path);
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
