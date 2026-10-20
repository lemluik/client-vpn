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

/// Что делает крестик на окне: `ask` спрашивает при каждом закрытии, `tray`
/// и `quit` — выбор, запомненный в этом самом запросе.
enum CloseAction {
  ask,
  tray,
  quit;

  static CloseAction named(String? value) =>
      values.firstWhere((action) => action.name == value, orElse: () => ask);
}

/// Настройки пользователя: оформление, запуск вместе с системой, крестик на
/// окне и память о последнем успешном подключении. Флаг автозапуска живёт не
/// здесь, а в системе.
class SettingsStore {
  SettingsStore._(
    this._prefs, {
    required this.themeChoice,
    required this.autoConnect,
    required this.closeAction,
    this.lastProfileId,
  });

  static const _themeKey = 'settings.theme';
  static const _autoConnectKey = 'settings.autoConnect';
  static const _lastProfileKey = 'settings.lastProfile';
  static const _closeActionKey = 'settings.closeAction';

  final SharedPreferences _prefs;

  ThemeChoice themeChoice;
  bool autoConnect;

  /// По умолчанию крестик спрашивает: молчаливый выход рвёт туннель, а
  /// молчаливый трей прячет окно так, что его не найти.
  CloseAction closeAction;

  /// Профиль, которым удалось подключиться в прошлый раз: именно его
  /// автоподключение поднимает снова.
  String? lastProfileId;

  static Future<SettingsStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore._(
      prefs,
      themeChoice: ThemeChoice.named(prefs.getString(_themeKey)),
      autoConnect: prefs.getBool(_autoConnectKey) ?? false,
      closeAction: CloseAction.named(prefs.getString(_closeActionKey)),
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

  Future<void> setCloseAction(CloseAction value) async {
    closeAction = value;
    await _prefs.setString(_closeActionKey, value.name);
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
