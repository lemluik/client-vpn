import 'dart:io';

import 'package:flutter/services.dart';

/// Запуск клиента вместе с системой. Флаг принадлежит системе, а не нам:
/// на Windows это значение в ключе реестра Run, на Android — разрешение,
/// которое читает загрузочный приёмник. Поэтому состояние перечитывается,
/// а не держится в настройках: правку извне клиент должен показывать как есть.
abstract class Autostart {
  const Autostart();

  /// false — платформа автозапуск не умеет, и настройку показывать нечего.
  bool get supported;

  Future<bool> isOn();

  Future<void> set(bool value);

  static Autostart platform() {
    if (Platform.isWindows) return WindowsAutostart();
    if (Platform.isAndroid) return const AndroidAutostart();
    return const UnsupportedAutostart();
  }
}

class UnsupportedAutostart extends Autostart {
  const UnsupportedAutostart();

  @override
  bool get supported => false;

  @override
  Future<bool> isOn() async => false;

  @override
  Future<void> set(bool value) async {}
}

/// HKCU\...\Run: запись читается после входа пользователя, прав администратора
/// не требует и снимается вместе с удалением программы из списка запуска.
class WindowsAutostart extends Autostart {
  WindowsAutostart({this.executable});

  static const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const valueName = 'ClientVPN';

  /// Путь к exe подменяется в проверке, чтобы тест не трогал реестр машины.
  final String? executable;

  @override
  bool get supported => true;

  String get executablePath => executable ?? Platform.resolvedExecutable;

  @override
  Future<bool> isOn() async {
    final result = await Process.run('reg', ['query', key, '/v', valueName]);
    return result.exitCode == 0;
  }

  @override
  Future<void> set(bool value) async {
    // Кавычки внутри значения обязательны: путь может содержать пробелы.
    final args = value
        ? [
            'add',
            key,
            '/v',
            valueName,
            '/t',
            'REG_SZ',
            '/d',
            '"$executablePath"',
            '/f',
          ]
        : ['delete', key, '/v', valueName, '/f'];
    final result = await Process.run('reg', args);
    if (result.exitCode != 0) {
      // Снятие отсутствующей записи — не ошибка: флаг и так выключен.
      if (value) {
        throw Exception('Система не приняла запись автозапуска: ${result.stderr}');
      }
    }
  }
}

/// Android: флаг лежит в нативном SharedPreferences под тем же именем, что
/// читает BootReceiver, а сам приёмник выключается компонентом, когда
/// пользователь отказался от автозапуска.
class AndroidAutostart extends Autostart {
  const AndroidAutostart();

  static const channel = MethodChannel('client_vpn/app');

  @override
  bool get supported => true;

  @override
  Future<bool> isOn() async =>
      await channel.invokeMethod<bool>('isAutoStart') ?? false;

  @override
  Future<void> set(bool value) =>
      channel.invokeMethod<void>('setAutoStart', value);
}
