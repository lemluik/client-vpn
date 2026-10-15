import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'app_proxy.dart';
import 'share_link.dart';
import 'subscription.dart';

/// Интервал автообновления по умолчанию, если провайдер не прислал заголовок.
const int defaultUpdateIntervalHours = 24;

/// Предел размера ответа провайдера: подписка на сотни узлов помещается с запасом,
/// а большой ответ чаще означает, что по адресу отдают не подписку.
const int maxSubscriptionBytes = 4 * 1024 * 1024;

/// Общий предел ожидания ответа: и соединение, и чтение.
const Duration subscriptionTimeout = Duration(seconds: 20);

const int _maxRedirects = 5;

/// Тело подписки и её заголовки — ровно то, что нужно слою разбора.
class SubscriptionResponse {
  const SubscriptionResponse({required this.body, this.headers = const {}});

  final String body;
  final Map<String, String> headers;
}

/// Способ получения подписки. В испытаниях подменяется заглушкой, чтобы не
/// ходить в сеть и проверять поведение на ошибках провайдера.
typedef SubscriptionFetcher = Future<SubscriptionResponse> Function(String url);

/// Итог обновления: провайдер в новом состоянии и текст ошибки, если он есть.
///
/// Кэш прошлой хорошей версии сохраняется в любом случае: при сбое пользователь
/// остаётся с рабочими профилями и может подняться без сети.
class RefreshResult {
  const RefreshResult(this.provider, {this.error});

  final Provider provider;
  final String? error;

  bool get ok => error == null;
}

/// Подписка одного провайдера: адрес, имя, интервал обновления и кэш.
class Provider {
  const Provider({
    required this.id,
    required this.url,
    this.name = '',
    this.updateIntervalHours = defaultUpdateIntervalHours,
    this.supportUrl,
    this.chatHomeserver,
    this.chatRoomId,
    this.lastUpdated,
    this.usage,
    this.cachedBody,
    this.lastError,
    this.frozen = false,
  });

  final String id;
  final String url;
  final String name;
  final int updateIntervalHours;
  final String? supportUrl;

  /// Узел чата поддержки из заголовка подписки. Null, если провайдер чат не даёт.
  final String? chatHomeserver;

  /// Комната чата: если провайдер её прислал, клиент не ищет её сам.
  final String? chatRoomId;
  final DateTime? lastUpdated;
  final SubscriptionUsage? usage;
  final String? cachedBody;
  final String? lastError;

  /// Провайдер заморозил подписку (`x-sub-status: frozen`): обновления не
  /// применяются, пока флаг не снимут (МК-5, P1-8 на стороне клиента).
  final bool frozen;

  /// Имя для интерфейса: провайдер может не прислать заголовок с названием.
  String get displayName => name.isNotEmpty ? name : url;

  bool get hasCache => cachedBody != null && cachedBody!.trim().isNotEmpty;

  /// Разобранная подписка из кэша. Null, если кэша нет.
  Subscription? get cached => hasCache ? parseSubscription(cachedBody!) : null;

  List<ShareLink> get links => cached?.links ?? const [];

  /// Пора ли обновляться. Без отметки о прошлом обновлении — всегда пора.
  bool needsUpdate(DateTime now) {
    final updated = lastUpdated;
    if (updated == null) return true;
    return now.difference(updated) >= Duration(hours: updateIntervalHours);
  }

  /// Доступ истёк по данным самого провайдера.
  bool accessEnded(DateTime now) => usage?.expiredAt(now) ?? false;

  Provider copyWith({
    String? name,
    int? updateIntervalHours,
    String? supportUrl,
    String? chatHomeserver,
    String? chatRoomId,
    DateTime? lastUpdated,
    SubscriptionUsage? usage,
    String? cachedBody,
    String? lastError,
    bool? frozen,
    bool clearError = false,
    bool clearSupportUrl = false,
    bool clearChat = false,
    bool clearChatRoom = false,
    bool clearUsage = false,
  }) {
    return Provider(
      id: id,
      url: url,
      name: name ?? this.name,
      updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
      supportUrl: clearSupportUrl ? null : (supportUrl ?? this.supportUrl),
      chatHomeserver: clearChat ? null : (chatHomeserver ?? this.chatHomeserver),
      chatRoomId: clearChat || clearChatRoom
          ? null
          : (chatRoomId ?? this.chatRoomId),
      lastUpdated: lastUpdated ?? this.lastUpdated,
      usage: clearUsage ? null : (usage ?? this.usage),
      cachedBody: cachedBody ?? this.cachedBody,
      lastError: clearError ? null : (lastError ?? this.lastError),
      frozen: frozen ?? this.frozen,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'interval': updateIntervalHours,
        'support': supportUrl,
        'chat': chatHomeserver,
        'chat_room': chatRoomId,
        'updated': lastUpdated?.toIso8601String(),
        'usage': _usageToJson(usage),
        'cache': cachedBody,
        'error': lastError,
        'frozen': frozen,
      };

  /// Разбирает сохранённого провайдера. Битая запись — это [FormatException],
  /// хранилище её пропускает и оставляет остальные.
  static Provider fromJson(Map<String, dynamic> json) {
    final url = _text(json['url']);
    if (url == null) throw const FormatException('У провайдера нет адреса');

    final interval = json['interval'];
    final usage = json['usage'];
    final updated = _text(json['updated']);

    return Provider(
      id: _text(json['id']) ?? providerIdOf(url),
      url: url,
      name: _text(json['name']) ?? '',
      updateIntervalHours: interval is int && interval > 0
          ? interval
          : defaultUpdateIntervalHours,
      supportUrl: _text(json['support']),
      chatHomeserver: _text(json['chat']),
      chatRoomId: _text(json['chat_room']),
      lastUpdated: updated == null ? null : DateTime.tryParse(updated),
      usage: usage is Map<String, dynamic> ? _usageFromJson(usage) : null,
      cachedBody: _text(json['cache']),
      lastError: _text(json['error']),
      frozen: json['frozen'] == true,
    );
  }
}

/// Устойчивый идентификатор провайдера по адресу: один адрес — одна запись.
String providerIdOf(String url) =>
    md5.convert(utf8.encode(url.trim())).toString();

/// Обновляет провайдера. Момент времени передаётся снаружи, чтобы поведение
/// можно было проверить испытанием.
Future<RefreshResult> refreshProvider(
  Provider provider, {
  required SubscriptionFetcher fetch,
  required DateTime now,
}) async {
  SubscriptionResponse response;
  try {
    response = await fetch(provider.url);
  } catch (error) {
    final text = messageOf(error);
    return RefreshResult(provider.copyWith(lastError: text), error: text);
  }

  final subscription = parseSubscription(
    response.body,
    headers: response.headers,
  );
  if (subscription.isEmpty) {
    const text = 'В ответе провайдера нет ни одного профиля';
    return RefreshResult(provider.copyWith(lastError: text), error: text);
  }

  final interval = subscription.updateInterval;
  if (subscription.frozen) {
    // Заморозка (МК-5): профили остаются те, что были, — провайдер отдаёт
    // последнюю хорошую версию, и менять кэш нет смысла.
    return RefreshResult(
      provider.copyWith(
        name: subscription.title,
        updateIntervalHours: interval?.inHours,
        supportUrl: subscription.supportUrl,
        clearSupportUrl: subscription.supportUrl == null,
        usage: subscription.usage,
        clearUsage: subscription.usage == null,
        lastUpdated: now,
        clearError: true,
        frozen: true,
      ),
    );
  }

  return RefreshResult(
    provider.copyWith(
      name: subscription.title,
      updateIntervalHours: interval?.inHours,
      supportUrl: subscription.supportUrl,
      clearSupportUrl: subscription.supportUrl == null,
      chatHomeserver: subscription.chatHomeserver,
      chatRoomId: subscription.chatRoomId,
      clearChat: subscription.chatHomeserver == null,
      clearChatRoom: subscription.chatRoomId == null,
      usage: subscription.usage,
      clearUsage: subscription.usage == null,
      cachedBody: subscription.links.map((link) => link.source).join('\n'),
      lastUpdated: now,
      clearError: true,
      frozen: false,
    ),
  );
}

/// Текст ошибки для интерфейса: без технических подробностей и без значений
/// из ответа провайдера.
String messageOf(Object error) {
  if (error is LinkFormatException) return error.message;
  if (error is TimeoutException) return 'Провайдер не ответил вовремя';
  if (error is SocketException) return 'Нет связи с провайдером';
  if (error is HandshakeException) {
    return 'Не удалось установить защищённое соединение';
  }
  if (error is HttpException) return 'Провайдер вернул ошибку';
  return 'Не удалось получить подписку';
}

/// Получает подписку по адресу. Принимаем только `http` и `https`: другие схемы
/// означают, что вместо адреса подписки вставили ссылку профиля.
Future<SubscriptionResponse> fetchSubscription(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const FormatException(
      'Адрес подписки начинается с http:// или https://',
    );
  }

  final client = HttpClient()
    ..connectionTimeout = subscriptionTimeout
    // Без этого HttpClient смотрит только переменные окружения (ТД-15).
    ..findProxy = AppProxy.findProxy;
  try {
    final request = await client.getUrl(uri).timeout(subscriptionTimeout);
    request.followRedirects = true;
    request.maxRedirects = _maxRedirects;

    final response = await request.close().timeout(subscriptionTimeout);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Код ответа ${response.statusCode}');
    }

    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });

    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxSubscriptionBytes) {
        throw const FormatException('Ответ провайдера слишком большой');
      }
    }

    return SubscriptionResponse(
      body: utf8.decode(bytes, allowMalformed: true),
      headers: headers,
    );
  } finally {
    client.close(force: true);
  }
}

String? _text(Object? value) {
  if (value is! String) return null;
  return value.isEmpty ? null : value;
}

Map<String, dynamic>? _usageToJson(SubscriptionUsage? usage) {
  if (usage == null) return null;
  return {
    'upload': usage.upload,
    'download': usage.download,
    'total': usage.total,
    'expire': usage.expire?.toIso8601String(),
  };
}

SubscriptionUsage? _usageFromJson(Map<String, dynamic> json) {
  final expire = json['expire'];
  return SubscriptionUsage(
    upload: json['upload'] is int ? json['upload'] as int : null,
    download: json['download'] is int ? json['download'] as int : null,
    total: json['total'] is int ? json['total'] as int : null,
    expire: expire is String ? DateTime.tryParse(expire) : null,
  );
}
