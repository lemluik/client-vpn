import 'dart:io';

import 'android_core.dart';
import 'desktop_core.dart';
import 'vpn_config.dart';

/// Общий для платформ интерфейс сетевого ядра.
///
/// Десктоп поднимает локальный прокси и переключает системные настройки,
/// Android — туннель VpnService. Интерфейс один, чтобы экран не знал
/// о платформе.
abstract class VpnCore {
  Stream<String> get logs;
  Stream<bool> get statusChanges;

  bool get isRunning;

  /// Короткое описание точки входа для строки статуса.
  String? get endpointLabel;

  /// Проверяет конфиг и бросает исключение с текстом для пользователя.
  Future<void> validate(VpnConfig config);

  Future<void> start(VpnConfig config);
  Future<void> stop();
  Future<void> dispose();

  /// Откатывает состояние, оставшееся после аварийного завершения.
  Future<void> recoverAfterCrash();
}

VpnCore createVpnCore() => Platform.isAndroid ? AndroidCore() : DesktopCore();
