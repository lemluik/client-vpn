import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_proxy.dart';
import 'registration_api.dart' show DeviceData;

/// A key issued to the service account and received by a one-time code.
///
/// The fields follow the grid in section 4 of the spec: name, entry label,
/// expiry, type, traffic left (filled only where the counter is kept).
class ClaimedKey {
  const ClaimedKey({
    required this.link,
    required this.name,
    this.entryLabel = '',
    this.expiresAt,
    this.trial = false,
    this.trafficLeftMb,
  });

  /// Connection link(s) (`vless://…`), one per line; the profile is built from them.
  final String link;
  final String name;

  /// Entry or region label as the server knows it.
  final String entryLabel;

  /// Expiry; null means no expiry (bot keys).
  final DateTime? expiresAt;

  /// A trial key or a regular one.
  final bool trial;
  final int? trafficLeftMb;

  /// Whether the key has expired at [now].
  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now);

  /// Parses one key of the `POST api/v1/keys` answer.
  ///
  /// The control point sends `links` (every entry of the cascade, one per line
  /// or as a list), `entry_labels` (a list) and `traffic_left_gb`. The older
  /// field names `key`/`link`, `entry`/`entry_label` and `traffic_left_mb` are
  /// still accepted. With only the old names the link stayed empty and a
  /// claimed key could not be added.
  factory ClaimedKey.fromJson(Map<String, dynamic> json) {
    final at = json['expires_at'];
    final links = json['links'];
    final labels = json['entry_labels'];
    final leftMb = json['traffic_left_mb'];
    final leftGb = json['traffic_left_gb'];
    return ClaimedKey(
      link: (json['key'] ?? json['link'] ??
              (links is List ? links.whereType<String>().join('\n') : links) ??
              '')
          as String,
      name: (json['name'] ?? '') as String,
      entryLabel: (json['entry'] ??
              json['entry_label'] ??
              (labels is List ? labels.whereType<String>().join(', ') : null) ??
              '')
          as String,
      expiresAt: at is String ? DateTime.tryParse(at) : null,
      trial: json['is_trial'] == true,
      trafficLeftMb: leftMb is num
          ? leftMb.toInt()
          : leftGb is num
          ? (leftGb * 1024).round()
          : null,
    );
  }
}

/// Key claim error: the text is shown to the user.
class KeyClaimException implements Exception {
  KeyClaimException(this.message, {this.connectionExpired = false});

  final String message;

  /// 404: the key expired between the list and connecting; the screen shows
  /// "connection ended" and offers a new code.
  final bool connectionExpired;

  @override
  String toString() => message;
}

/// Key claim transport. The screen knows only this interface: a change of the
/// contract (code -> list of keys) is one edit in the implementation, not a
/// rewrite of the interface. Same approach as `TrayPort` and `FakeTrayPort`.
abstract class KeyClaimApi {
  /// Returns the active keys of the code owner. No Telegram login is asked for
  /// or sent: the one-time code itself is the authenticator (§2, option a2).
  Future<List<ClaimedKey>> claim({
    required String code,
    required DeviceData device,
  });
}

/// The request body is built apart from the exchange: a test pins its fields,
/// so "the code is the only secret sent" is checked by the number of fields.
/// The control point validates `claim_code`; with `code` it answered 422.
Map<String, dynamic> keyClaimRequest(String code, DeviceData device) => {
  'claim_code': code,
  ...device.toJson(),
};

/// The real exchange with the control point: HTTPS with strict certificate
/// checks; the address comes from the deployment config, not from the code.
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

  /// A short reason for the status code (§7.3: 401 code not accepted,
  /// 429 too many attempts, 404 the key is no longer valid).
  static String reasonFor(int status) => switch (status) {
    HttpStatus.unauthorized => 'Код не принят — запросите новый в чате сервиса',
    HttpStatus.tooManyRequests => 'Слишком много попыток — попробуйте позже',
    HttpStatus.notFound => 'Подключение закончилось',
    _ => 'Сервис недоступен (код $status)',
  };
}
