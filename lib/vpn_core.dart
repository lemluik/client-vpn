import 'dart:io';

import 'android_core.dart';
import 'desktop_core.dart';
import 'vpn_config.dart';

/// Статус ядра вместе с признаком, откуда пришла команда.
///
/// `byShell` — команда из оболочки (плитка шторки), а не из приложения:
/// остановка по такой команде не сбой, и переподключение её не взводит.
class CoreStatus {
  const CoreStatus(this.running, {this.byShell = false});

  final bool running;
  final bool byShell;

  factory CoreStatus.fromPayload(Object? payload) {
    if (payload is Map) {
      return CoreStatus(
        payload['running'] == true,
        byShell: payload['byShell'] == true,
      );
    }
    return CoreStatus(payload == true);
  }
}

/// Общий для платформ интерфейс сетевого ядра.
///
/// Десктоп поднимает локальный прокси и переключает системные настройки,
/// Android — туннель VpnService. Интерфейс один, чтобы экран не знал
/// о платформе.
abstract class VpnCore {
  Stream<String> get logs;
  Stream<CoreStatus> get statusChanges;

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

  /// Помечает сохранённый конфиг туннеля как свежий: с этого момента оболочка
  /// (плитка шторки) имеет право поднимать туннель без открытия приложения.
  Future<void> markTunnelFresh();

  /// Забирает команду «подключить из шторки», если она пришла на эту активность.
  Future<bool> takePendingConnect();
}

VpnCore createVpnCore() => Platform.isAndroid ? AndroidCore() : DesktopCore();
