import 'dart:async';

import 'package:flutter/services.dart';

/// Канал глубоких ссылок: обработчик на стороне Android поднят в MainActivity.
const String _channelName = 'client_vpn/deep_link';

/// Глубокая ссылка подключения: тап в браузере или мессенджере открывает
/// клиента по стандартной схеме протокола (`vless://`, `trojan://`, `vmess://`),
/// а ОС передаёт саму ссылку по этому каналу.
///
/// `OptionalMethodChannel` отдаёт null там, где обработчика нет — на десктопе и
/// в тестовой среде, — поэтому отдельной ветки по платформе не нужно.
///
/// Поток с одним слушателем: событие лежит в окладе до подписки, поэтому
/// ссылка холодного старта не теряется, даже если состояние подпишется позже.
Stream<String> deepLinkStream({
  OptionalMethodChannel channel = const OptionalMethodChannel(_channelName),
}) {
  final links = StreamController<String>();
  channel.setMethodCallHandler((call) async {
    final link = call.arguments;
    if (call.method == 'link' && link is String) links.add(link);
  });
  channel.invokeMethod<String>('takePending').then((link) {
    if (link != null) links.add(link);
  });
  return links.stream;
}
