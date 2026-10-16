import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

/// Выбор темы: как в большинстве клиентов — следим за системой или форсируем.
///
/// Названия тем interface берёт из локализации: модель работает до первого
/// кадра, а язык известен только в виджете.
enum ThemeChoice {
  system(ThemeMode.system),
  light(ThemeMode.light),
  dark(ThemeMode.dark);

  const ThemeChoice(this.mode);

  final ThemeMode mode;

  static ThemeChoice named(String? value) =>
      values.firstWhere((choice) => choice.name == value, orElse: () => system);
}

/// Настройки пользователя: оформление, автоподключение и память о последнем
/// успешном подключении. Автозапуск сюда не входит — его флаг живёт в системе.
class SettingsStore {
  SettingsStore._(
    this._prefs, {
    required this.themeChoice,
    required this.autoConnect,
    this.lastProfileId,
  });

  static const _themeKey = 'settings.theme';
  static const _autoConnectKey = 'settings.autoConnect';
  static const _lastProfileKey = 'settings.lastProfile';

  final SharedPreferences _prefs;

  ThemeChoice themeChoice;
  bool autoConnect;

  /// Профиль, которым удалось подключиться в прошлый раз: именно его
  /// автоподключение поднимает снова.
  String? lastProfileId;

  static Future<SettingsStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore._(
      prefs,
      themeChoice: ThemeChoice.named(prefs.getString(_themeKey)),
      autoConnect: prefs.getBool(_autoConnectKey) ?? false,
      lastProfileId: prefs.getString(_lastProfileKey),
    );
  }

  Future<void> setTheme(ThemeChoice value) async {
    themeChoice = value;
    await _prefs.setString(_themeKey, value.name);
  }

  Future<void> setAutoConnect(bool value) async {
    autoConnect = value;
    await _prefs.setBool(_autoConnectKey, value);
  }

  Future<void> rememberProfile(String id) async {
    if (lastProfileId == id) return;
    lastProfileId = id;
    await _prefs.setString(_lastProfileKey, id);
  }

  /// Профиль удалён — напоминание о нём держать не о чем, иначе
  /// автоподключение будет искать несуществующее подключение.
  Future<void> forgetProfile(String id) async {
    if (lastProfileId != id) return;
    lastProfileId = null;
    await _prefs.remove(_lastProfileKey);
  }
}
