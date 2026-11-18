import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_proxy.dart';

/// Данные устройства, которые клиент отправляет при подключении пробного ключа.
///
/// Географию (страна, город) определяет сервер по IP — клиент её не собирает и
/// не отправляет (§4.1). Идентификатор — случайный UUID, не аппаратный номер.
class DeviceData {
  const DeviceData({
    required this.deviceId,
    required this.platform,
    required this.appVersion,
  });

  final String deviceId;
  final String platform;
  final String appVersion;

  Map<String, dynamic> toJson() => {
    'device_id': deviceId,
    'platform': platform,
    'app_version': appVersion,
  };
}

/// Ответ точки контроля: ключ и метаданные программы тестирования (§3.3).
class RegistrationResult {
  const RegistrationResult({
    required this.key,
    required this.serviceName,
    this.expiresAt,
    this.trafficLimitGb,
    this.subscriptionUrl,
    this.program = '',
    this.validUntil,
  });

  /// Ключ подключения (`vless://…`) — из него клиент собирает профиль.
  final String key;
  final String serviceName;
  final DateTime? expiresAt;
  final int? trafficLimitGb;
  final String? subscriptionUrl;
  final String program;
  final String? validUntil;

  factory RegistrationResult.fromJson(Map<String, dynamic> json) {
    Object? at = json['expires_at'];
    return RegistrationResult(
      key: json['key'] as String,
      serviceName: (json['service_name'] as String?) ?? '',
      expiresAt: at is String ? DateTime.tryParse(at) : null,
      trafficLimitGb: (json['traffic_limit_gb'] as num?)?.toInt(),
      subscriptionUrl: json['subscription_url'] as String?,
      program: (json['program'] as String?) ?? '',
      validUntil: json['valid_until'] as String?,
    );
  }
}

/// Ошибка подключения с текст-причиной для строки «Не удалось подключиться: …».
class RegistrationException implements Exception {
  RegistrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Порт API пробного ключа. В испытаниях подменяется заглушкой — сеть не
/// поднимается, ответ задаёт тест.
abstract class RegistrationApi {
  Future<RegistrationResult> register({
    required String telegramLogin,
    required DeviceData device,
  });
}

/// Предел размера ответа точки контроля: ключ и метаданные — это килобайты,
/// а огромный ответ означает, что адрес отдаёт не результат регистрации.
const int maxRegistrationBytes = 256 * 1024;

/// Настоящий обмен с точкой контроля: HTTPS со строгой проверкой сертификата.
/// Никаких `badCertificateCallback` и обходов — как в `matrix_api.dart`. Адрес
/// приходит из конфигурации, в коде не зашит (гейт нейтральности У-8).
class HttpRegistrationApi implements RegistrationApi {
  HttpRegistrationApi({
    required String controlPoint,
    HttpClient? client,
    Duration timeout = const Duration(seconds: 20),
  }) : _controlPoint = controlPoint,
       _client = client,
       _timeout = timeout;

  final String _controlPoint;
  final HttpClient? _client;
  final Duration _timeout;

  @override
  Future<RegistrationResult> register({
    required String telegramLogin,
    required DeviceData device,
  }) async {
    final base = _controlPoint.endsWith('/')
        ? _controlPoint
        : '$_controlPoint/';
    final uri = Uri.parse('${base}api/v1/register');
    final body = jsonEncode({
      'telegram_login': telegramLogin,
      ...device.toJson(),
    });

    // Запрос идёт через ядро, когда подключение поднято (ТД-15); до подключения
    // findProxy возвращает прямой путь.
    final owned = _client == null;
    final client =
        _client ??
        (HttpClient()
          ..connectionTimeout = _timeout
          ..findProxy = AppProxy.findProxy);
    try {
      final request = await client.openUrl('POST', uri).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(_timeout);
      // Чтение ответа ограничено и по времени, и по размеру: сервер может
      // прислать заголовки и не завершить тело — без предела ожидание
      // зависло бы навсегда.
      final text = await _readBody(response).timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw RegistrationException(_reason(response.statusCode));
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw RegistrationException('Сервис ответил неверно');
      }
      return RegistrationResult.fromJson(decoded);
    } on RegistrationException {
      rethrow;
    } on TimeoutException {
      throw RegistrationException('Сервис не отвечает — попробуйте позже');
    } catch (_) {
      throw RegistrationException('Не удалось связаться с сервисом');
    } finally {
      // Клиент, созданный внутри, закрываем; переданный извне остаётся
      // вызывающему: без явного контракта владения закрывать его нельзя.
      if (owned) client.close(force: true);
    }
  }

  Future<String> _readBody(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxRegistrationBytes) {
        throw RegistrationException('Ответ сервиса слишком большой');
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Короткая причина по коду ответа: её показывает строка ошибки на экране.
  static String _reason(int status) => switch (status) {
    HttpStatus.tooManyRequests => 'Слишком много попыток — попробуйте позже',
    HttpStatus.forbidden => 'Пробный ключ на этом устройстве уже использован',
    HttpStatus.conflict => 'Пробный ключ уже выдан',
    HttpStatus.badRequest => 'Проверьте введённые данные',
    _ => 'Сервис недоступен (код $status)',
  };
}
