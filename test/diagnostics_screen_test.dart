import 'dart:async';

import 'package:client_vpn/app_proxy.dart';
import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/diagnostics.dart';
import 'package:client_vpn/diagnostics_screen.dart';
import 'package:client_vpn/path_probe.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/provider.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Вымышленный узел: адрес тестовый, ключи не боевые.
const _link =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.test:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.test'
    '&flow=xtls-rprx-vision#Alpha';

const _subscriptionUrl = 'https://example.test/sub';

/// Ядро-заглушка: считает запуски, не поднимает настоящий туннель.
class _Core implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<CoreStatus> _status =
      StreamController<CoreStatus>.broadcast();
  int startCalls = 0;
  bool _running = false;

  @override
  Stream<String> get logs => _logs.stream;
  @override
  Stream<CoreStatus> get statusChanges => _status.stream;
  @override
  bool get isRunning => _running;
  @override
  String? get endpointLabel => null;
  @override
  Future<void> validate(VpnConfig config) async {}
  @override
  Future<void> start(VpnConfig config) async {
    startCalls++;
    _running = true;
    _status.add(const CoreStatus(true));
  }
  @override
  Future<void> stop() async {
    _running = false;
    _status.add(const CoreStatus(false));
  }
  @override
  Future<void> dispose() async {}
  @override
  Future<void> recoverAfterCrash() async {}
  @override
  Future<void> markTunnelFresh() async {}
  @override
  Future<bool> takePendingConnect() async => false;
}

Future<(AppState, _Core)> _state() async {
  SharedPreferences.setMockInitialValues({});
  final store = await ProfileStore.open();
  Future<SubscriptionResponse> fetch(String url) async =>
      const SubscriptionResponse(body: _link);
  final added = await store.addSubscription(_subscriptionUrl, fetch: fetch);
  await store.setActive(added.profile!.id);

  final core = _Core();
  final state = AppState(
    store,
    core,
    settings: await SettingsStore.open(),
    configWriter: (config) async => config,
    pathProbe: PathProbe(attempt: (_) async => true, reachesCore: () => true),
    subscriptionFetch: fetch,
    diagnosticsProbe:
        (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) async =>
            const ProbeOutcome(statusCode: 204),
  );
  return (state, core);
}

Future<void> _pumpScreen(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(MaterialApp(home: DiagnosticsScreen(state: state)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('выключенный VPN: предложение подключиться вместо кнопок проверки',
      (tester) async {
    final (state, _) = await _state();
    addTearDown(state.dispose);

    await _pumpScreen(tester, state);

    expect(find.textContaining('VPN выключен'), findsOneWidget);
    expect(find.text('Подключить и проверить'), findsOneWidget);
    expect(find.text('Проверить все входы'), findsNothing);
    expect(
      find.widgetWithText(FilledButton, 'Проверить соединение'),
      findsNothing,
    );
  });

  testWidgets('одно нажатие поднимает туннель и сразу выполняет проверку',
      (tester) async {
    final (state, core) = await _state();
    addTearDown(state.dispose);
    // Собственный трафик приложения идёт через ядро: путь проверяем.
    AppProxy.attach((protocol: 'http', port: 10809));
    addTearDown(() => AppProxy.attach(null));

    await _pumpScreen(tester, state);
    await tester.tap(find.text('Подключить и проверить'));
    await tester.pumpAndSettle();

    expect(core.startCalls, 1);
    expect(state.state, TunnelState.on);
    expect(state.diagnostics, isNotNull);
    expect(state.diagnostics!.verdict, DiagVerdict.works);
    expect(find.text('Соединение работает'), findsOneWidget);
    // После подключения экран показывает обычные кнопки проверки.
    expect(find.text('Проверить все входы'), findsOneWidget);
    expect(find.text('Подключить и проверить'), findsNothing);

    // Отключение снимает пробу пути: таймеров после теста не остаётся.
    await state.disconnect();
    await tester.pumpAndSettle();
  });

  testWidgets('поднятый туннель: обычные кнопки, предложения подключиться нет',
      (tester) async {
    final (state, _) = await _state();
    addTearDown(state.dispose);
    await state.connect();

    await _pumpScreen(tester, state);

    expect(
      find.widgetWithText(FilledButton, 'Проверить соединение'),
      findsOneWidget,
    );
    expect(find.text('Проверить все входы'), findsOneWidget);
    expect(find.text('Подключить и проверить'), findsNothing);
    expect(find.textContaining('VPN выключен'), findsNothing);

    await state.disconnect();
    await tester.pumpAndSettle();
  });
}