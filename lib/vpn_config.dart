import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Конфиг Xray, который выбрал пользователь.
class VpnConfig {
  const VpnConfig({required this.name, required this.json, this.path});

  /// Имя файла — показывается в интерфейсе.
  final String name;

  /// Полное содержимое config.json.
  final String json;

  /// Путь на диске. Есть только на десктопе: там ядро читает файл само.
  final String? path;
}

const _pathKey = 'config_path';
const _nameKey = 'config_name';
const _jsonKey = 'config_json';

/// Диалог выбора файла. На мобильной платформе путь — это content URI,
/// которым нельзя открыть файл напрямую, поэтому содержимое читается сразу.
Future<VpnConfig?> pickVpnConfig() async {
  final picked = await FilePicker.pickFile(
    dialogTitle: 'Выберите config.json',
    type: FileType.custom,
    allowedExtensions: ['json'],
  );
  if (picked == null) return null;

  return VpnConfig(
    name: picked.name,
    json: utf8.decode(await picked.readAsBytes()),
    path: picked.path,
  );
}

Future<void> saveVpnConfig(VpnConfig config) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_nameKey, config.name);
  if (config.path != null) {
    await prefs.setString(_pathKey, config.path!);
    return;
  }
  await prefs.setString(_jsonKey, config.json);
}

/// Восстанавливает конфиг после перезапуска приложения.
/// На десктопе файл перечитывается с диска — он мог измениться.
Future<VpnConfig?> loadSavedVpnConfig() async {
  final prefs = await SharedPreferences.getInstance();
  final name = prefs.getString(_nameKey);

  final path = prefs.getString(_pathKey);
  if (path != null) {
    final file = File(path);
    if (!await file.exists()) return null;
    return VpnConfig(
      name: name ?? path.split(Platform.pathSeparator).last,
      json: await file.readAsString(),
      path: path,
    );
  }

  final json = prefs.getString(_jsonKey);
  if (json == null) return null;
  return VpnConfig(name: name ?? 'config.json', json: json);
}
