import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Приложение, которое пользователь может вывести из туннеля.
typedef InstalledApp = ({String package, String name});

/// Запись списка приложений, идущих напрямую.
typedef AppExclusionsWriter = Future<void> Function(List<String> packages);

/// Нативный канал Android для правил по приложениям (R2.3).
///
/// Ядро тут ни при чём: Xray не умеет условие по имени пакета (замер
/// 16.10.2026), список читает `VpnService` на поднятии туннеля.
class PerAppChannel {
  const PerAppChannel([this._channel = _defaultChannel]);

  static const _defaultChannel = MethodChannel('client_vpn/tunnel');

  final MethodChannel _channel;

  /// Пакеты, которые система показывает как запускаемые приложения.
  Future<List<InstalledApp>> list() async {
    final raw = await _channel.invokeMethod<List<Object?>>('listApps');
    if (raw == null) return const [];
    final apps = <InstalledApp>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final package = item['package'];
      final name = item['name'];
      if (package is! String || name is! String) continue;
      apps.add((package: package, name: name));
    }
    return apps;
  }

  /// Передаёт нативной части список исключений перед подключением.
  Future<void> write(List<String> packages) =>
      _channel.invokeMethod<void>('setExcludedApps', packages);
}

/// Хранение выбранных приложений на устройстве.
class PerAppStore {
  const PerAppStore(this._prefs);

  static const _key = 'routing.apps.v1';

  final SharedPreferences _prefs;

  List<String> load() => _prefs.getStringList(_key) ?? const [];

  Future<void> save(List<String> packages) =>
      _prefs.setStringList(_key, packages);
}
