import 'dart:io';

import 'package:client_vpn/windows_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  // Распаковка проверяется настоящим tar: bsdtar в Windows штатный и читает zip,
  // GNU-tar — нет. Проверяем ровно то, на чём приложение работает.
  final skipUnpack =
      Platform.isWindows ? false : 'распаковка — только на Windows';

  test('имя staging-каталога не содержит недопустимых символов', () {
    expect(WindowsUpdater.stagingDirName('0.4.2'), 'v0.4.2');
    expect(WindowsUpdater.stagingDirName('0.4.2+7'), 'v0.4.2_7');
    expect(WindowsUpdater.stagingDirName('0.4.2/beta'), 'v0.4.2_beta');
  });

  group('распаковка архива', () {
    late Directory work;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('cvpn_updater_test');
    });
    tearDown(() => work.delete(recursive: true));

    Future<String> zipOf(Directory source, String name) async {
      final archive = p.join(work.path, name);
      final result = await Process.run(
        'tar',
        ['-a', '-c', '-f', archive, '-C', source.path, '.'],
      );
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      return archive;
    }

    test('файлы в корне архива дают пакет со вложенными каталогами', () async {
      final build = await Directory(p.join(work.path, 'build')).create();
      await File(p.join(build.path, WindowsUpdater.exeName)).writeAsString('exe');
      await File(p.join(build.path, 'flutter_assets', 'AssetManifest.bin'))
          .create(recursive: true)
          .then((f) => f.writeAsString('assets'));

      final updater = await WindowsUpdater.stage(
        archivePath: await zipOf(build, 'loose.zip'),
        version: '0.4.2',
        workRoot: work,
      );
      expect(updater, isNotNull);
      expect(
        await File(p.join(updater!.staging.path, WindowsUpdater.exeName))
            .exists(),
        isTrue,
      );
      expect(
        await File(p.join(
                updater.staging.path, 'flutter_assets', 'AssetManifest.bin'))
            .exists(),
        isTrue,
      );
      // журнал нужен для приёмки: он переживает выход приложения
      expect(updater.logFile.path, contains('client_vpn_update'));
    }, skip: skipUnpack);

    test('сборка в одной папке внутри архива тоже находится', () async {
      final outer = await Directory(p.join(work.path, 'wrapped')).create();
      final inner = await Directory(p.join(outer.path, 'Release')).create();
      await File(p.join(inner.path, WindowsUpdater.exeName)).writeAsString('exe');

      final updater = await WindowsUpdater.stage(
        archivePath: await zipOf(outer, 'wrapped.zip'),
        version: '0.4.3',
        workRoot: work,
      );
      expect(
        await File(p.join(updater!.staging.path, WindowsUpdater.exeName))
            .exists(),
        isTrue,
      );
    }, skip: skipUnpack);

    test('архив без exe пакетом не считается', () async {
      final junk = await Directory(p.join(work.path, 'junk')).create();
      await File(p.join(junk.path, 'readme.txt')).writeAsString('не сборка');

      final updater = await WindowsUpdater.stage(
        archivePath: await zipOf(junk, 'junk.zip'),
        version: '0.4.4',
        workRoot: work,
      );
      expect(updater, isNull);
    }, skip: skipUnpack);
  });
}
