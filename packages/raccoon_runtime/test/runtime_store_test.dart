import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

List<int> _linuxEmbedderZip() {
  final archive =
      Archive()
        ..addFile(
          ArchiveFile.bytes('libflutter_engine.so', [0x7f, 0x45, 0x4c, 0x46]),
        )
        ..addFile(
          ArchiveFile.string(
            'flutter_embedder.h',
            '#define FLUTTER_ENGINE_VERSION 1\n',
          ),
        );
  return ZipEncoder().encodeBytes(archive);
}

/// The framework zip's shape: the contents of FlutterEmbedder.framework at
/// the root, with the usual links into Versions/A.
List<int> _darwinEmbedderZip() {
  final archive =
      Archive()
        ..addFile(ArchiveFile.bytes('Versions/A/FlutterEmbedder', [0xcf, 0xfa]))
        ..addFile(
          ArchiveFile.string(
            'Versions/A/Headers/FlutterEmbedder.h',
            '#define FLUTTER_ENGINE_VERSION 1\n',
          ),
        )
        ..addFile(_symlink('Versions/Current', 'A'))
        ..addFile(
          _symlink('FlutterEmbedder', 'Versions/Current/FlutterEmbedder'),
        )
        ..addFile(_symlink('Headers', 'Versions/Current/Headers'));
  return _madeOnUnix(ZipEncoder().encodeBytes(archive));
}

/// A zip stores a symbolic link as an entry in link mode whose bytes are the
/// target.
ArchiveFile _symlink(String name, String target) =>
    ArchiveFile.string(name, target)..mode = 0xA1FF;

/// The archive package writes every zip as made on MS-DOS and reads link
/// modes only from zips made on Unix, which the bucket's are: stamp each
/// central directory entry's "version made by" with Unix.
Uint8List _madeOnUnix(List<int> zip) {
  final bytes = Uint8List.fromList(zip);
  final data = ByteData.sublistView(bytes);
  const endSignature = 0x06054b50;
  const entrySignature = 0x02014b50;
  const unix = 3;
  var end = bytes.length - 22;
  while (data.getUint32(end, Endian.little) != endSignature) {
    end--;
  }
  var entry = data.getUint32(end + 16, Endian.little);
  while (data.getUint32(entry, Endian.little) == entrySignature) {
    bytes[entry + 5] = unix;
    final nameLength = data.getUint16(entry + 28, Endian.little);
    final extraLength = data.getUint16(entry + 30, Endian.little);
    final commentLength = data.getUint16(entry + 32, Endian.little);
    entry += 46 + nameLength + extraLength + commentLength;
  }
  return bytes;
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_store'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('names the platform the way the bucket does', () {
    expect(RuntimeStore.platformFor('linux', Abi.linuxX64), 'linux-x64');
    expect(RuntimeStore.platformFor('linux', Abi.linuxArm64), 'linux-arm64');
    expect(RuntimeStore.platformFor('macos', Abi.macosArm64), 'darwin');
    expect(RuntimeStore.platformFor('macos', Abi.macosX64), 'darwin');
    expect(RuntimeStore.platformFor('windows', Abi.windowsX64), 'windows-x64');
    expect(
      () => RuntimeStore.platformFor('fuchsia', Abi.fuchsiaArm64),
      throwsUnsupportedError,
    );
  });

  test('artifact uri follows the bucket layout', () {
    expect(
      RuntimeStore.artifactUri('abc123', platform: 'linux-x64').toString(),
      'https://storage.googleapis.com/flutter_infra_release/flutter/abc123/linux-x64/linux-x64-embedder.zip',
    );
    expect(
      RuntimeStore.artifactUri('abc123', platform: 'darwin').toString(),
      'https://storage.googleapis.com/flutter_infra_release/flutter/abc123/darwin-x64/FlutterEmbedder.framework.zip',
    );
  });

  test('knows where each host keeps its library and icu data', () {
    expect(RuntimeStore.engineLibraryOf('linux-arm64'), 'libflutter_engine.so');
    expect(RuntimeStore.engineLibraryOf('windows-x64'), 'flutter_engine.dll');
    expect(
      RuntimeStore.engineLibraryOf('darwin'),
      p.join('FlutterEmbedder.framework', 'FlutterEmbedder'),
    );
    final engines = p.join('/sdk', 'bin', 'cache', 'artifacts', 'engine');
    expect(
      RuntimeStore.icuDataOfSdk('/sdk', platform: 'linux-x64'),
      p.join(engines, 'linux-x64', 'icudtl.dat'),
    );
    expect(
      RuntimeStore.icuDataOfSdk('/sdk', platform: 'darwin'),
      p.join(engines, 'darwin-x64', 'icudtl.dat'),
    );
    expect(
      RuntimeStore.icuDataOfSdk('/sdk', platform: 'windows-x64'),
      p.join(engines, 'windows-x64', 'icudtl.dat'),
    );
  });

  test('finds the home on Windows too, where HOME is seldom set', () {
    expect(RuntimeStore.homeOf({'HOME': '/h', 'USERPROFILE': 'C:/u'}), '/h');
    expect(
      RuntimeStore.homeOf({'USERPROFILE': r'C:\Users\me'}),
      r'C:\Users\me',
    );
    expect(
      RuntimeStore.forHost({'USERPROFILE': r'C:\Users\me'}).cacheDirectory,
      p.join(r'C:\Users\me', '.cache', 'raccoon', 'engines'),
    );
  });

  test('reads the engine revision from the sdk stamp', () {
    final sdk = Directory(p.join(temp.path, 'sdk', 'bin', 'cache'))
      ..createSync(recursive: true);
    File(p.join(sdk.path, 'engine.stamp')).writeAsStringSync('deadbeef\n');

    expect(RuntimeStore.revisionOfSdk(p.join(temp.path, 'sdk')), 'deadbeef');
    expect(RuntimeStore.revisionOfSdk(p.join(temp.path, 'nope')), isNull);
  });

  test(
    'ensure downloads, extracts and then finds the runtime installed',
    () async {
      final requested = <Uri>[];
      final store = RuntimeStore(
        cacheDirectory: p.join(temp.path, 'engines'),
        platform: 'linux-x64',
        download: (uri) async {
          requested.add(uri);
          return _linuxEmbedderZip();
        },
      );

      expect(store.installed('rev1'), isNull);
      final runtime = await store.ensure('rev1');

      expect(runtime.revision, 'rev1');
      expect(File(runtime.engineLibrary).existsSync(), isTrue);
      expect(
        File(runtime.embedderHeader).readAsStringSync(),
        contains('FLUTTER_ENGINE_VERSION'),
      );
      expect(store.installed('rev1')?.directory, runtime.directory);
      expect(requested, [
        RuntimeStore.artifactUri('rev1', platform: 'linux-x64'),
      ]);

      await store.ensure('rev1');
      expect(requested, hasLength(1), reason: 'no second download');
    },
  );

  test('ensure unpacks the macOS framework with its links', () async {
    final store = RuntimeStore(
      cacheDirectory: p.join(temp.path, 'engines'),
      platform: 'darwin',
      download: (_) async => _darwinEmbedderZip(),
    );

    final runtime = await store.ensure('rev1');

    expect(runtime.directory, endsWith(p.join('rev1', 'darwin')));
    expect(
      File(runtime.engineLibrary).resolveSymbolicLinksSync(),
      endsWith(p.join('Versions', 'A', 'FlutterEmbedder')),
    );
    expect(
      File(runtime.embedderHeader).readAsStringSync(),
      contains('FLUTTER_ENGINE_VERSION'),
    );
    expect(store.installed('rev1'), isNotNull);
  }, skip: Platform.isWindows ? 'symbolic links' : false);

  test('ensure rejects an archive without the engine library', () async {
    final store = RuntimeStore(
      cacheDirectory: p.join(temp.path, 'engines'),
      platform: 'linux-x64',
      download:
          (_) async => ZipEncoder().encodeBytes(
            Archive()..addFile(ArchiveFile.string('README', 'empty')),
          ),
    );

    expect(store.ensure('rev2'), throwsStateError);
  });
}
