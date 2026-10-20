import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'app_proxy.dart';
import 'proxy_config.dart';
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
  final StreamController<CoreStatus> _statusController =
      StreamController<CoreStatus>.broadcast();

  bool _running = false;
  String? _endpoint;
  String? _tunJson;

  /// Локальный http-вход поднятого туннеля — точка для собственного трафика
  /// приложения (ТД-15). Пока конфиг не собран, берётся то же значение, которое
  /// в него ставится.
  ProxyEndpoint? _local;

  /// Поднимает или снимает путь приложения через ядро.
  void _ownTraffic(bool running) =>
      AppProxy.attach(running ? (_local ?? appProxyEndpoint()) : null);

  @override
  Stream<String> get logs => _logController.stream;

  @override
  Stream<CoreStatus> get statusChanges => _statusController.stream;

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
        final status = CoreStatus.fromPayload(call.arguments);
        _running = status.running;
        _ownTraffic(_running);
        _statusController.add(status);
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
    _local = parseProxyInbound(tunJson);
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
    _ownTraffic(true);
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
    _ownTraffic(false);
  }

  @override
  Future<void> recoverAfterCrash() async {
    // Туннель Android снимает сам вместе с остановкой сервиса, но состояние
    // сервиса переживает закрытие экрана: его надо спросить, иначе UI
    // отрисуется «Отключён» при поднятом туннеле.
    final status = CoreStatus.fromPayload(
      await _channel.invokeMethod<Object>('status'),
    );
    _running = status.running;
    _ownTraffic(_running);
    _statusController.add(status);
  }

  @override
  Future<void> markTunnelFresh() => _channel.invokeMethod<void>('markTunnelFresh');

  @override
  Future<bool> takePendingConnect() async =>
      await _channel.invokeMethod<bool>('takePendingConnect') == true;

  @override
  Future<void> dispose() async {
    await stop();
    _channel.setMethodCallHandler(null);
    await _logController.close();
    await _statusController.close();
  }
}
