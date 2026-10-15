import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/reconnect.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const linkOne = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%95%D0%B2%D1%80%D0%BE%D0%BF%D0%B0%201';

/// Ядро, которое считает подъёмы и умеет умирать само — как при обрыве канала.
class KillableCore implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<bool> _status = StreamController<bool>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  bool _running = false;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  Stream<bool> get statusChanges => _status.stream;

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
    _status.add(true);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _running = false;
    _status.add(false);
  }

  /// Ядро умерло само: приложение этого не просило.
  void kill() {
    _running = false;
    _status.add(false);
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> recoverAfterCrash() async {}
}

/// Состояние с короткой лестницей: испытание не ждёт реальные минуты.
/// [probeInterval] задаёт отдельно: когда по сценарию пауза подписки или
/// возврат сети должны сработать раньше пробы, проба не должна их перебрать.
Future<(AppState, StreamController<List<ConnectivityResult>>)> watched(
  KillableCore core, {
  Duration probeInterval = const Duration(milliseconds: 60),
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = await ProfileStore.open();
  final profile = await store.addLinks(
    name: 'Европа',
    links: parseLinks(linkOne).links,
  );
  await store.setActive(profile.id);

  final networks = StreamController<List<ConnectivityResult>>();
  final state = AppState(
    store,
    core,
    configWriter: (config) async => config,
    reconnect: ReconnectPlan(
      pauses: const [
        Duration(milliseconds: 120),
        Duration(milliseconds: 240),
        Duration(milliseconds: 360),
      ],
      probeInterval: probeInterval,
    ),
    networks: networks.stream,
  );
  return (state, networks);
}

Future<void> settle([int ms = 30]) => Future<void>.delayed(
      Duration(milliseconds: ms),
    );

void main() {
  group('лестница переподключений', () {
    test(' паузы берутся из спецификации: 1, 5 и 30 минут', () {
      expect(subscriptionPauses, const [
        Duration(minutes: 1),
        Duration(minutes: 5),
        Duration(minutes: 30),
      ]);
      expect(linkProbeInterval, const Duration(seconds: 30));
    });

    test('три шага, потом лестница исчерпана и не растёт', () {
      final plan = ReconnectPlan();

      expect(plan.takePause(), const Duration(minutes: 1));
      expect(plan.takePause(), const Duration(minutes: 5));
      expect(plan.takePause(), const Duration(minutes: 30));
      expect(plan.exhausted, isTrue);
      // Четвёртая пауза не выдумывается: держим верхний шаг.
      expect(plan.nextPause(), const Duration(minutes: 30));

      plan.reset();
      expect(plan.step, 0);
      expect(plan.nextPause(), const Duration(minutes: 1));
    });
  });

  group('переподключение после сбоя (МК-5)', () {
    test('ядро умерло — проба туннеля поднимает его без пользователя',
        () async {
      final core = KillableCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      expect(state.state, TunnelState.on);

      core.kill();
      await settle();
      expect(state.state, TunnelState.failure);
      expect(state.isReconnecting, isTrue);

      await settle(120);
      expect(core.startCalls, 2);
      expect(state.state, TunnelState.on);
      expect(state.isReconnecting, isFalse);
      expect(state.log, contains('Проба связи: подключаемся снова'));
    });

    test('пауза подписки перечитывает её и не оставляет план висеть',
        () async {
      // Проба длиннее паузы: поднимать туннель в этом сценарии обязано
      // перечитывание подписки, а не проба.
      final core = KillableCore();
      final (state, networks) = await watched(
        core,
        probeInterval: const Duration(seconds: 30),
      );
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      core.kill();
      await settle(200);

      expect(state.log, contains('Перечитываем подписку после сбоя'));
      expect(state.state, TunnelState.on);
      expect(core.startCalls, 2);
      // План погашен успешным подъёмом: ничего не висит в очереди.
      expect(state.isReconnecting, isFalse);
      expect(state.reconnectStep, 0);
    });

    test('отключение пользователя отменяет очередь переподключений', () async {
      final core = KillableCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      core.kill();
      await settle();
      expect(state.isReconnecting, isTrue);

      await state.disconnect();
      final starts = core.startCalls;
      await settle(300);

      expect(core.startCalls, starts);
      expect(state.isReconnecting, isFalse);
    });

    test('пропажа сети — «нет связи», возврат сети поднимает туннель сразу',
        () async {
      final core = KillableCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();

      networks.add([ConnectivityResult.none]);
      await settle();
      expect(state.state, TunnelState.noLink);
      expect(state.failure, isNull);

      networks.add([ConnectivityResult.mobile]);
      await settle(2500);
      expect(core.startCalls, 2);
      expect(core.stopCalls, 1);
      expect(state.state, TunnelState.on);
      expect(state.log, contains('Сеть появилась — туннель поднимается заново'));
    });
  });
}
