import 'dart:convert';

import 'share_link.dart';

/// Заголовки профиля, которые присылают провайдеры. Имена приводим к нижнему
/// регистру: регистр в ответах не стабилен, а сравнивать нужно надёжно.
const String _titleHeader = 'profile-title';
const String _intervalHeader = 'profile-update-interval';
const String _usageHeader = 'subscription-userinfo';
const String _supportHeader = 'support-url';

/// Настройки чата поддержки приходят теми же заголовками, что и остальное:
/// адрес узла Matrix и комната. В код клиента адреса провайдера не вписываются.
const String _chatHomeserverHeader = 'chat-homeserver';
const String _chatRoomHeader = 'chat-room';

/// Остаток трафика и срок доступа из заголовка `subscription-userinfo`.
///
/// Провайдер присылает байты и секунды эпохи. Срок сравниваем с переданным
/// моментом, а не с «сейчас», чтобы поведение можно было проверить тестом.
class SubscriptionUsage {
  const SubscriptionUsage({
    this.upload,
    this.download,
    this.total,
    this.expire,
  });

  final int? upload;
  final int? download;
  final int? total;
  final DateTime? expire;

  /// Осталось байт. Null, если провайдер не сообщил предел.
  int? get remaining {
    if (total == null || upload == null || download == null) return null;
    final left = total! - upload! - download!;
    return left < 0 ? 0 : left;
  }

  bool expiredAt(DateTime moment) => expire != null && !expire!.isAfter(moment);

  /// Разбирает `upload=0; download=1024; total=2048; expire=1700000000`.
  static SubscriptionUsage? parse(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;

    final values = <String, String>{};
    for (final part in text.split(';')) {
      final pair = part.split('=');
      if (pair.length != 2) continue;
      values[pair[0].trim().toLowerCase()] = pair[1].trim();
    }
    if (values.isEmpty) return null;

    int? number(String key) => int.tryParse(values[key] ?? '');
    final expireSeconds = number('expire');

    return SubscriptionUsage(
      upload: number('upload'),
      download: number('download'),
      total: number('total'),
      // `expire=0` у провайдеров означает «без срока», а не 1 января 1970 года.
      expire: expireSeconds == null || expireSeconds <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              expireSeconds * 1000,
              isUtc: true,
            ),
    );
  }
}

/// Подписка провайдера: профили плюс сведения из заголовков ответа.
class Subscription {
  const Subscription({
    required this.links,
    required this.skipped,
    this.title,
    this.updateInterval,
    this.supportUrl,
    this.chatHomeserver,
    this.chatRoomId,
    this.usage,
  });

  final List<ShareLink> links;
  final List<SkippedLink> skipped;

  /// Имя подписки из `profile-title`; провайдер может его не прислать.
  final String? title;

  /// Интервал автообновления: в заголовке провайдер даёт часы.
  final Duration? updateInterval;

  /// Адрес поддержки провайдера из `support-url`.
  final String? supportUrl;

  /// Узел чата из `chat-homeserver`: полный `https://хост:порт`.
  final String? chatHomeserver;

  /// Комната чата из `chat-room`: без него клиент берёт первую комнату из `/sync`.
  final String? chatRoomId;

  final SubscriptionUsage? usage;

  bool get isEmpty => links.isEmpty;
}

/// Разбирает ответ провайдера: тело подписки и её заголовки.
///
/// Тело бывает и открытым списком ссылок, и base64-обёрткой того же списка —
/// принимаем оба варианта. Заголовки необязательны: без них подписка
/// остаётся рабочей, просто без имени и без интервала обновления.
Subscription parseSubscription(
  String body, {
  Map<String, String> headers = const {},
}) {
  final result = parseLinks(_decodeBody(body));
  final normalized = {
    for (final header in headers.entries)
      header.key.trim().toLowerCase(): header.value,
  };
  final hours = int.tryParse((normalized[_intervalHeader] ?? '').trim());

  return Subscription(
    links: result.links,
    skipped: result.skipped,
    title: _decodedTitle(normalized[_titleHeader]),
    updateInterval: hours == null || hours <= 0 ? null : Duration(hours: hours),
    supportUrl: _nonEmpty(normalized[_supportHeader]),
    chatHomeserver: _nonEmpty(normalized[_chatHomeserverHeader]),
    chatRoomId: _nonEmpty(normalized[_chatRoomHeader]),
    usage: SubscriptionUsage.parse(normalized[_usageHeader]),
  );
}

/// Экспорт в том же формате, в каком подписка приходит: ссылки через перевод
/// строки, по умолчанию обёрнутые в base64.
String encodeSubscription(Iterable<ShareLink> links, {bool asBase64 = true}) {
  final text = links.map((link) => link.source).join('\n');
  return asBase64 ? base64.encode(utf8.encode(text)) : text;
}

String _decodeBody(String body) {
  final text = body.trim();
  if (text.isEmpty) return '';
  return _tryBase64Text(text) ?? text;
}

String? _decodedTitle(String? raw) {
  final value = _nonEmpty(raw);
  if (value == null) return null;
  return _tryBase64Text(value) ?? value;
}

/// Распознаёт base64-обёртку по алфавиту: в открытом списке ссылок всегда есть
/// `://`, `?` и `#`, которых в base64 не бывает. Если значение не декодируется
/// в текст, возвращаем null — вызывающая сторона оставит его как есть.
String? _tryBase64Text(String value) {
  final compact = value.replaceAll(RegExp(r'\s'), '');
  if (compact.length < 4) return null;
  if (!RegExp(r'^[A-Za-z0-9+/_-]+=*$').hasMatch(compact)) return null;
  try {
    return utf8.decode(decodeBase64Loose(compact));
  } on FormatException {
    return null;
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
