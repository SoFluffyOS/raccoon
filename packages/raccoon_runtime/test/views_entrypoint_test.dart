import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:raccoon_runtime/raccoon_runtime.dart';
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('raccoon_entry');
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: wonders\n');
  });
  tearDown(() => project.deleteSync(recursive: true));

  test('the entry imports the app\'s main by its package', () {
    final entry = ViewsEntrypoint.write(project.path);
    expect(
      entry,
      p.join(project.path, '.dart_tool', 'raccoon', 'views_main.dart'),
    );
    final source = File(entry!).readAsStringSync();
    expect(source, contains("import 'package:wonders/main.dart' as app;"));
    expect(source, contains('wrapWithDefaultView'));

    final other = ViewsEntrypoint.write(
      project.path,
      target: 'lib/src/dev.dart',
    );
    expect(
      File(other!).readAsStringSync(),
      contains("import 'package:wonders/src/dev.dart' as app;"),
    );
  });

  test('a main outside lib, or a project without a name, has none', () {
    expect(
      ViewsEntrypoint.write(project.path, target: 'tool/main.dart'),
      isNull,
    );
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('version: 1\n');
    expect(ViewsEntrypoint.write(project.path), isNull);
  });

  test('an entry that is the same is not written again', () {
    final entry = File(ViewsEntrypoint.write(project.path)!);
    final written = DateTime(2000);
    entry.setLastModifiedSync(written);
    ViewsEntrypoint.write(project.path);
    expect(entry.lastModifiedSync(), written);
  });
}
