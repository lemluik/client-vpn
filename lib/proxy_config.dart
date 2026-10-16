import 'dart:convert';

/// Локальная точка входа прокси, описанная в config.json.
typedef ProxyEndpoint = ({String protocol, int port});

/// Ищет в конфиге локальную точку входа: сначала `http`, затем `socks`.
///
/// Порядок не алфавитный и не по конфигу: замерено (ТД-11), что браузер с
/// записью `socks=адрес:порт` в реестре резолвит назначение сам и передаёт
/// ядру адрес — запрос имени уходит наружу через провайдера. Запись без
/// префикса означает http-прокси, и ядро получает домен.
///
/// Возвращает null, если подходящего inbound нет. В этом случае подключаться
/// нельзя: без локального прокси системные настройки не меняются, а трафик
/// идёт напрямую, хотя интерфейс показывал бы «Подключён».
ProxyEndpoint? parseProxyInbound(String jsonContent) {
  final decoded = jsonDecode(jsonContent);
  if (decoded is! Map) return null;

  final inbounds = decoded['inbounds'];
  if (inbounds is! List) return null;

  ProxyEndpoint? socks;
  for (final inbound in inbounds) {
    if (inbound is! Map) continue;

    final protocol = inbound['protocol'];
    if (protocol != 'http' && protocol != 'socks') continue;

    final port = parsePort(inbound['port']);
    if (port == null) continue;

    final endpoint = (protocol: protocol as String, port: port);
    if (endpoint.protocol == 'http') return endpoint;
    socks ??= endpoint;
  }
  return socks;
}

/// Порт в конфиге Xray встречается и числом, и строкой — принимаем оба варианта.
int? parsePort(dynamic raw) => switch (raw) {
      final int value => value,
      final String value => int.tryParse(value.trim()),
      _ => null,
    };
