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
    return ServiceConfig(
      serviceName: _nonEmpty(product) ?? defaultServiceName,
      controlPoint: _nonEmpty(json['controlPoint']),
      trialEnabled: trial is Map && trial['enabled'] == true,
    );
  }

  static String? _nonEmpty(Object? value) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }
}
