import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_proxy.dart';
import 'registration_api.dart' show DeviceData;

/// Ключ, выданный аккаунту сервиса и полученный по одноразовому коду.
///
/// Поля соответствуют сетке раздела 4 спецификации: имя, метка входа, срок,
/// тип, остаток трафика (заполняется только там, где счётчик ведётся).
class ClaimedKey {
  const ClaimedKey({
    required this.link,
    required this.name,
    this.entryLabel = '',
    this.expiresAt,
    this.trial = false,
    this.trafficLeftMb,
  });

  /// Ссылка подключения (`vless://…`) — из неё создаётся профиль.
  final String link;
  final String name;

  /// Метка входа или региона, как её знает сервер.
  final String entryLabel;

  /// Окончание срока; null — «без срока» (бот-ключи).
  final DateTime? expiresAt;

  /// Пробный ключ или обычный.
  final bool trial;
  final int? trafficLeftMb;

  /// Истёк ли ключ на момент [now].
  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now);

  factory ClaimedKey.fromJson(Map<String, dynamic> json) {
    final at = json['expires_at'];
    final left = json['traffic_left_mb'];
    return ClaimedKey(
      link: (json['key'] ?? json['link'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      entryLabel: (json['entry'] ?? json['entry_label'] ?? '') as String,
      expiresAt: at is String ? DateTime.tryParse(at) : null,
      trial: json['is_trial'] == true,
      trafficLeftMb: left is num ? left.toInt() : null,
    );
  }
}

/// Ошибка авторецепта: текст показывается пользователю.
class KeyClaimException implements Exception {
  KeyClaimException(this.message, {this.connectionExpired = false});

  final String message;

  /// 404: ключ истёк между списком и подключением — экран показывает
  /// «подключение закончилось» и предлагает новый код.
  final bool connectionExpired;

  @override
  String toString() => message;
}

/// Транспорт авторецепта. Экран знает только этот интерфейс: смена варианта
/// контракта (код → список ключей) — одна правка в реализации, не переписывание
/// интерфейса. Приём — как с `TrayPort` и `FakeTrayPort` в тестах.
abstract class KeyClaimApi {
  /// Отдаёт действующие ключи владельца кода. Логин Telegram не запрашивается
  /// и не отправляется: аутентификатор — сам одноразовый код (§2, вариант а2).
  Future<List<ClaimedKey>> claim({
    required String code,
    required DeviceData device,
  });
}

/// Тело запроса собрано отдельно от обмена: тест фиксирует состав, и
/// «код — единственный передаваемый секрет» проверяется числом полей.
Map<String, dynamic> keyClaimRequest(String code, DeviceData device) => {
  'code': code,
  ...device.toJson(),
};

/// Настоящий обмен с точкой контроля: HTTPS со строгой проверкой сертификата,
/// адрес приходит из конфигурации внедрения, в коде не зашит.
class HttpKeyClaimApi implements KeyClaimApi {
  HttpKeyClaimApi({
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
  Future<List<ClaimedKey>> claim({
    required String code,
    required DeviceData device,
  }) async {
    final base = _controlPoint.endsWith('/')
        ? _controlPoint
        : '$_controlPoint/';
    final uri = Uri.parse('${base}api/v1/keys');
    final body = jsonEncode(keyClaimRequest(code, device));

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
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw KeyClaimException(
          reasonFor(response.statusCode),
          connectionExpired: response.statusCode == HttpStatus.notFound,
        );
      }
      final decoded = jsonDecode(text);
      final list = decoded is Map<String, dynamic> ? decoded['keys'] : decoded;
      if (list is! List) {
        throw KeyClaimException('Сервис ответил неверно');
      }
      return [
        for (final item in list)
          if (item is Map<String, dynamic>) ClaimedKey.fromJson(item),
      ];
    } on KeyClaimException {
      rethrow;
    } on TimeoutException {
      throw KeyClaimException('Сервис не отвечает — попробуйте позже');
    } catch (_) {
      throw KeyClaimException('Не удалось связаться с сервисом');
    }
  }

  /// Короткая причина по коду ответа (§7.3: 401 — код не принят,
  /// 429 — лимит попыток, 404 — ключ больше не действителен).
  static String reasonFor(int status) => switch (status) {
    HttpStatus.unauthorized => 'Код не принят — запросите новый в чате сервиса',
    HttpStatus.tooManyRequests => 'Слишком много попыток — попробуйте позже',
    HttpStatus.notFound => 'Подключение закончилось',
    _ => 'Сервис недоступен (код $status)',
  };
}
