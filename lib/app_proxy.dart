import 'proxy_config.dart';

/// Точка входа, через которую собственный HTTP-трафик приложения уходит в ядро.
///
/// Без этой точки запросы подписки и чата идут мимо канала на обеих
/// платформах: `Dart HttpClient` по умолчанию берёт прокси из переменных
/// окружения, а не из системных настроек (`_http/http_impl.dart:2795`), поэтому
/// записанный в реестр `ProxyServer` на Windows и туннель VpnService на Android
/// ему не видны (ТД-12).
final class AppProxy {
  /// Мишень запроса → значение для `HttpClient.findProxy`.
  ///
  /// Возвращает `DIRECT`, когда подключения нет, когда цель — петлевой адрес
  /// (ядро само слушает на нём: гнать такой запрос через канал бессмысленно),
  /// и когда локальный вход описан как socks: `dart:io` умеет вести HttpClient
  /// только через http-прокси, поддержки SOCKS в библиотеке нет (проверено по
  /// исходникам SDK 3.13.5 — подстроки `SOCKS` в `_http` нет).
  static String findProxy(Uri target) {
    final endpoint = _endpoint;
    if (endpoint == null || endpoint.protocol != 'http') return 'DIRECT';
    if (isLoopbackHost(target.host)) return 'DIRECT';
    return 'PROXY 127.0.0.1:${endpoint.port}';
  }

  static ProxyEndpoint? _endpoint;

  /// Локальная точка входа поднятого подключения или null.
  static ProxyEndpoint? get endpoint => _endpoint;

  /// Собственный трафик приложения сейчас идёт через ядро?
  static bool get reachesCore => endpoint?.protocol == 'http';

  /// Ставит точку входа при подключении и снимает при остановке ([endpoint] —
  /// null). Снятие обязательно: с мёртвым портом запросы висели бы на таймаут.
  static void attach(ProxyEndpoint? endpoint) => _endpoint = endpoint;

  /// Петлевой адрес в любой форме, с которой к нам приходят: имя или цифра,
  /// IPv6 в скобках или без.
  static bool isLoopbackHost(String host) {
    final name = host.trim();
    if (name.isEmpty) return false;
    if (name == 'localhost' || name.endsWith('.localhost')) return true;
    // Литерал IPv6 в адресе URI приходит в скобках: `[::1]`.
    final bare = name.replaceAll(RegExp(r'^\[|\]$'), '');
    if (bare == '::1' || bare == '0::1') return true;
    if (bare.startsWith('127.')) return true;
    final octets = bare.split('.');
    if (octets.length == 4 &&
        octets.every((part) => int.tryParse(part) != null)) {
      return int.parse(octets.first) == 127;
    }
    return false;
  }
}
