import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'tun_config.dart';
import 'vpn_config.dart';
import 'vpn_core.dart';

/// Ядро на Android: туннель поднимает нативный VpnService,
/// Dart готовит конфиг и слушает события.
class AndroidCore implements VpnCore {
  AndroidCore() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel('client_vpn/tunnel');

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  final StreamController<bool> _statusController =
      StreamController<bool>.broadcast();

  bool _running = false;
  String? _endpoint;
  String? _tunJson;

  @override
  Stream<String> get logs => _logController.stream;

  @override
  Stream<bool> get statusChanges => _statusController.stream;

  @override
  bool get isRunning => _running;

  @override
  String? get endpointLabel => _endpoint;

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'log':
        final line = call.arguments;
        if (line is String && line.isNotEmpty) _logController.add(line);
      case 'status':
        _running = call.arguments == true;
        _statusController.add(_running);
      default:
        break;
    }
  }

  @override
  Future<void> validate(VpnConfig config) async {
    String tunJson;
    try {
      tunJson = buildTunConfig(config.json);
    } on FormatException catch (e) {
      throw Exception('Конфиг не читается: ${e.message}');
    }
    _tunJson = tunJson;
    _endpoint = _describeOutbound(config.json);

    // Проверяется именно тот конфиг, который пойдёт в туннель, а не конфиг
    // пользователя: ядро ловит ошибки маршрутизации, балансёра и DNS до того,
    // как пользователь подтвердит поднятие туннеля.
    await _channel.invokeMethod<void>('validate', tunConfigForTest(tunJson));
  }

  /// Адрес дальней стороны из первого прокси-outbound — для строки статуса.
  String? _describeOutbound(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      final outbounds = decoded['outbounds'];
      if (outbounds is! List) return null;

      for (final outbound in outbounds) {
        if (outbound is! Map) continue;
        final protocol = outbound['protocol'];
        if (protocol is! String || !proxyProtocols.contains(protocol)) continue;

        final vnext = (outbound['settings'] as Map?)?['vnext'];
        if (vnext is! List || vnext.isEmpty) return protocol;
        final server = vnext.first;
        if (server is! Map) return protocol;
        return '${server['address']}:${server['port']}';
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> start(VpnConfig config) async {
    final tunJson = _tunJson ??= buildTunConfig(config.json);
    final started = await _channel.invokeMethod<bool>('start', tunJson);
    if (started != true) {
      throw Exception(
        'Android не разрешил поднять туннель. '
        'Подтвердите запрос системы и повторите подключение.',
      );
    }
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<void> recoverAfterCrash() async {
    // Туннель Android снимает сам вместе с остановкой сервиса, но состояние
    // сервиса переживает закрытие экрана: его надо спросить, иначе UI
    // отрисуется «Отключён» при поднятом туннеле.
    _running = await _channel.invokeMethod<bool>('status') == true;
    _statusController.add(_running);
  }

  @override
  Future<void> dispose() async {
    await stop();
    _channel.setMethodCallHandler(null);
    await _logController.close();
    await _statusController.close();
  }
}
