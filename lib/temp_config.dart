import 'dart:io';

import 'package:path/path.dart' as p;

import 'vpn_config.dart';

const String _fileName = 'config.json';

Directory? _working;

/// Рабочая папка служебного конфига. Отдельная на каждый запуск: второй
/// экземпляр клиента не должен перезаписывать конфиг работающего.
Directory workingDirectory() => _working ??= Directory(
      p.join(Directory.systemTemp.path, 'client_vpn-$pid'),
    );

/// Ядро на десктопе читает конфиг только с диска, поэтому собранный в памяти
/// конфиг перед запуском записывается в рабочую папку. Файл пользователя при
/// этом не создаётся и не меняется: он остаётся необязательным.
Future<VpnConfig> ensureConfigOnDisk(VpnConfig config) async {
  final path = config.path;
  if (path != null) return config;

  final directory = workingDirectory();
  await directory.create(recursive: true);
  final file = File(p.join(directory.path, _fileName));
  await file.writeAsString(config.json);

  return VpnConfig(name: config.name, json: config.json, path: file.path);
}

/// Убирает служебный конфиг при выходе: в нём лежат ключи пользователя.
Future<void> clearWorkingDirectory() async {
  final directory = _working;
  if (directory == null) return;
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
  _working = null;
}
