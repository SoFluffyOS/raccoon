import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

List<int> _embedderZip() {
  final archive = Archive()
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

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('raccoon_store'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('artifact uri follows the bucket layout', () {
    expect(
      RuntimeStore.artifactUri('abc123').toString(),
      'https://storage.googleapis.com/flutter_infra_release/flutter/abc123/linux-x64/linux-x64-embedder.zip',
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
        download: (uri) async {
          requested.add(uri);
          return _embedderZip();
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
      expect(requested, [RuntimeStore.artifactUri('rev1')]);

      await store.ensure('rev1');
      expect(requested, hasLength(1), reason: 'no second download');
    },
  );

  test('ensure rejects an archive without the engine library', () async {
    final store = RuntimeStore(
      cacheDirectory: p.join(temp.path, 'engines'),
      download: (_) async => ZipEncoder().encodeBytes(
        Archive()..addFile(ArchiveFile.string('README', 'empty')),
      ),
    );

    expect(store.ensure('rev2'), throwsStateError);
  });
}
