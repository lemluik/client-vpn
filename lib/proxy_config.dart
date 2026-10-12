import 'dart:convert';

/// Локальная точка входа прокси, описанная в config.json.
typedef ProxyEndpoint = ({String protocol, int port});

/// Ищет в конфиге Xray первый inbound с протоколом `http` или `socks`.
///
/// Возвращает null, если подходящего inbound нет. В этом случае подключаться
/// нельзя: без локального прокси системные настройки не меняются, а трафик
/// идёт напрямую, хотя интерфейс показывал бы «Подключён».
ProxyEndpoint? parseProxyInbound(String jsonContent) {
  final decoded = jsonDecode(jsonContent);
  if (decoded is! Map) return null;

  final inbounds = decoded['inbounds'];
  if (inbounds is! List) return null;

  for (final inbound in inbounds) {
    if (inbound is! Map) continue;

    final protocol = inbound['protocol'];
    if (protocol != 'http' && protocol != 'socks') continue;

    final port = parsePort(inbound['port']);
    if (port == null) continue;

    return (protocol: protocol as String, port: port);
  }
  return null;
}

/// Порт в конфиге Xray встречается и числом, и строкой — принимаем оба варианта.
int? parsePort(dynamic raw) => switch (raw) {
      final int value => value,
      final String value => int.tryParse(value.trim()),
      _ => null,
    };
