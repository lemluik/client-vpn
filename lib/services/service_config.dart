import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Конфигурация сервиса подключения: имя для надписей и координаты точки
/// контроля, на которой клиент запрашивает пробный ключ.
///
/// В открытом клиенте ассета нет — значение по умолчанию нейтральное, клиент
/// остаётся универсальным (гейт `tools/neutral_check.py`). В закрытой сборке
/// данные накладывает приватный слой (`overlay/deployment.json`), поэтому бренд
/// и адреса приезжают из конфигурации, а не компилируются в код.
class ServiceConfig {
  const ServiceConfig({
    this.serviceName = defaultServiceName,
    this.controlPoint,
    this.trialEnabled = false,
    this.updateFeed,
    this.updateChannel,
    this.updatePublicKey,
  });

  /// Нейтральное имя, когда бренд не задан: кнопка читается «Подключить сервис».
  static const String defaultServiceName = 'сервис';

  /// Путь конфиг-ассета. В открытом репозитории файла нет: [load] ловит
  /// отсутствие и возвращает значения по умолчанию.
  static const String assetPath = 'assets/service_config.json';

  /// Имя сервиса для надписей (заголовок экрана, кнопка меню «+»).
  final String serviceName;

  /// Базовый адрес точки контроля (API пробного ключа). Без него ключ не
  /// запросить; значение приходит из конфигурации, а не из кода.
  final String? controlPoint;

  /// Показывать ли подключение пробного ключа. Признак из `deployment.json`
  /// (`trial.enabled`): в открытом клиенте выключен, меню остаётся универсальным.
  final bool trialEnabled;

  /// Точка раздачи обновлений (Р-92): адрес манифеста. Приходит из приватного
  /// слоя сборки, в открытом клиенте отсутствует — там источником остаётся
  /// публичный репозиторий релизов.
  final String? updateFeed;

  /// Канал обновлений: `closed` у закрытой сборки. Канал задаёт конфигурация
  /// сборки, а не введённый пользователем адрес: иначе ссылка на публичный
  /// репозиторий молча переводила бы закрытую сборку на открытый пакет.
  final String? updateChannel;

  /// Публичный ключ Ed25519 (32 байта, base64) для проверки подписи манифеста.
  /// Публичный ключ — не секрет; приватный ключ подписи в сборку не попадает.
  final String? updatePublicKey;

  /// Загрузка из ассета сборки. Отсутствие файла или битый JSON — не ошибка:
  /// возвращаем нейтральные значения по умолчанию, клиент остаётся рабочим.
  static Future<ServiceConfig> load({AssetBundle? bundle}) async {
    final String raw;
    try {
      raw = await (bundle ?? rootBundle).loadString(assetPath);
    } catch (_) {
      return const ServiceConfig();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const ServiceConfig();
      return ServiceConfig.fromJson(decoded);
    } catch (_) {
      return const ServiceConfig();
    }
  }

  /// Разбор формата `deployment.json` (см. `overlay/deployment.example.json`):
  /// имя — из `brand.productName`, признак пробного ключа — из `trial.enabled`.
  factory ServiceConfig.fromJson(Map<String, dynamic> json) {
    final brand = json['brand'];
    final product = brand is Map ? brand['productName'] : null;
    final trial = json['trial'];
    final update = json['update'];
    return ServiceConfig(
      serviceName: _nonEmpty(product) ?? defaultServiceName,
      controlPoint: _nonEmpty(json['controlPoint']),
      trialEnabled: trial is Map && trial['enabled'] == true,
      updateFeed: update is Map ? _nonEmpty(update['feed']) : null,
      updateChannel: update is Map ? _nonEmpty(update['channel']) : null,
      updatePublicKey: update is Map ? _nonEmpty(update['publicKey']) : null,
    );
  }

  static String? _nonEmpty(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }
}
