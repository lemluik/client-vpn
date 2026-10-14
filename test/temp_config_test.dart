import 'dart:io';

import 'package:client_vpn/temp_config.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() async => clearWorkingDirectory());

  group('ensureConfigOnDisk', () {
    test('конфиг из памяти записывается в рабочую папку', () async {
      const config = VpnConfig(name: 'Подписка', json: '{"inbounds":[]}');

      final onDisk = await ensureConfigOnDisk(config);

      expect(onDisk.name, 'Подписка');
      expect(onDisk.path, isNotNull);
      expect(onDisk.path, contains('client_vpn-'));
      expect(File(onDisk.path!).readAsStringSync(), '{"inbounds":[]}');
    });

    test('файл пользователя остаётся нетронутым', () async {
      final folder = await Directory.systemTemp.createTemp('cvpn-test-');
      final userFile = File('${folder.path}/config.json');
      await userFile.writeAsString('{"log":{}}');

      final config = VpnConfig(
        name: 'config.json',
        json: '{"inbounds":[]}',
        path: userFile.path,
      );
      final result = await ensureConfigOnDisk(config);

      expect(result.path, userFile.path);
      expect(userFile.readAsStringSync(), '{"log":{}}');
      await folder.delete(recursive: true);
    });

    test('повторная запись обновляет служебный конфиг', () async {
      final first = await ensureConfigOnDisk(
        const VpnConfig(name: 'Первый', json: '{"a":1}'),
      );
      final second = await ensureConfigOnDisk(
        const VpnConfig(name: 'Второй', json: '{"b":2}'),
      );

      expect(second.path, first.path);
      expect(File(second.path!).readAsStringSync(), '{"b":2}');
    });

    test('после выхода служебного конфига не остаётся', () async {
      final onDisk = await ensureConfigOnDisk(
        const VpnConfig(name: 'Подписка', json: '{"inbounds":[]}'),
      );

      await clearWorkingDirectory();

      expect(File(onDisk.path!).existsSync(), isFalse);
    });
  });
}
