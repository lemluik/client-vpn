import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/android_core.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/reconnect.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const linkOne = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%95%D0%B2%D1%80%D0%BE%D0%BF%D0%B0%201';

/// Ядро, которым умеет управлять оболочка: команды из плитки приходят событиями
/// статуса с признаком `byShell`.
class ShellCore implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<CoreStatus> _status =
      StreamController<CoreStatus>.broadcast();

  int startCalls = 0;
  int stopCalls = 0;
  bool _running = false;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  Stream<CoreStatus> get statusChanges => _status.stream;

  @override
  Future<void> markTunnelFresh() async {}

  @override
  Future<bool> takePendingConnect() async => false;

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
    stopCalls++;
    _running = false;
    _status.add(const CoreStatus(false));
  }

  /// Туннель снят плиткой: приложение об этом не просило.
  void shellStop() {
    _running = false;
    _status.add(const CoreStatus(false, byShell: true));
  }

  /// Туннель поднят плиткой.
  void shellStart() {
    _running = true;
    _status.add(const CoreStatus(true, byShell: true));
  }

  /// Ядро умерло само — это сбой, и отличить его от плитки обязано состояние.
  void kill() {
    _running = false;
    _status.add(const CoreStatus(false));
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> recoverAfterCrash() async {}
}

Future<(AppState, StreamController<List<ConnectivityResult>>)> watched(
  ShellCore core,
) async {
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
    settings: await SettingsStore.open(),
    configWriter: (config) async => config,
    reconnect: ReconnectPlan(
      pauses: const [Duration(milliseconds: 120)],
      probeInterval: const Duration(milliseconds: 60),
    ),
    networks: networks.stream,
  );
  return (state, networks);
}

Future<void> settle([int ms = 30]) => Future<void>.delayed(
      Duration(milliseconds: ms),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('событие статуса с признаком оболочки', () {
    test('карта с двумя полями разбирается целиком', () {
      final status = CoreStatus.fromPayload({
        'running': true,
        'byShell': true,
      });
      expect(status.running, isTrue);
      expect(status.byShell, isTrue);
    });

    test('отсутствующий или чужой признак читается как команда из приложения',
        () {
      expect(
        CoreStatus.fromPayload({'running': false}).byShell,
        isFalse,
      );
      expect(CoreStatus.fromPayload(false).running, isFalse);
      expect(CoreStatus.fromPayload(null).running, isFalse);
    });
  });

  group('остановка из шторки (главный дефект карточки)', () {
    test('не показывает сбой и не взводит лестницу переподключения', () async {
      final core = ShellCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      expect(state.state, TunnelState.on);

      core.shellStop();
      await settle();

      expect(state.state, TunnelState.off);
      expect(state.failure, isNull);
      expect(state.log, isNot(contains('Соединение прервано')));
      expect(state.isReconnecting, isFalse);

      // Ни проба, ни пауза подписки туннель обратно не поднимают.
      await settle(300);
      expect(core.startCalls, 1);
      expect(state.state, TunnelState.off);
    });

    test('смерть ядра без признака оболочки по-прежнему считается сбоем',
        () async {
      final core = ShellCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      core.kill();
      await settle();

      expect(state.state, TunnelState.failure);
      expect(state.failure?.message, 'Соединение прервано');
      expect(state.isReconnecting, isTrue);
    });

    test('после остановки плиткой подъём из приложения работает', () async {
      final core = ShellCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      core.shellStop();
      await settle();

      await state.connect();
      expect(state.state, TunnelState.on);
      expect(core.startCalls, 2);
    });
  });

  group('подъём из шторки', () {
    test('ставит намерение пользователя, и переподъём при смене сети работает',
        () async {
      final core = ShellCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      core.shellStart();
      await settle();
      expect(state.state, TunnelState.on);

      networks.add([ConnectivityResult.none]);
      await settle();
      expect(state.state, TunnelState.noLink);

      networks.add([ConnectivityResult.mobile]);
      await settle(2500);

      expect(state.state, TunnelState.on);
      expect(state.log, contains('Сеть появилась — туннель поднимается заново'));
    });

    test('подъём вне приложения не оставляет интерфейс в «подключении»',
        () async {
      final core = ShellCore();
      final (state, networks) = await watched(core);
      addTearDown(state.dispose);

      networks.add([ConnectivityResult.wifi]);
      core.shellStart();
      await settle();

      expect(state.state, TunnelState.on);
      expect(state.isBusy, isFalse);
    });
  });

  group('метка свежести и команда из плитки (нативный канал)', () {
    const channel = MethodChannel('client_vpn/tunnel');
    final calls = <MethodCall>[];

    void mockNative(Object? Function(MethodCall call) answer) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return answer(call);
      });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      calls.clear();
    });

    test('AndroidCore просит метку свежести и забирает команду один раз',
        () async {
      var pending = true;
      mockNative((call) {
        if (call.method != 'takePendingConnect') return null;
        final answer = pending;
        pending = false;
        return answer;
      });

      final core = AndroidCore();
      await core.markTunnelFresh();
      expect(await core.takePendingConnect(), isTrue);
      expect(await core.takePendingConnect(), isFalse);

      expect(calls.map((call) => call.method),
          ['markTunnelFresh', 'takePendingConnect', 'takePendingConnect']);
    });

    test('событие статуса из нативной части доходит до состояния с признаком',
        () async {
      final messenger = TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger;
      final core = AndroidCore();
      final seen = <CoreStatus>[];
      core.statusChanges.listen(seen.add);
      await settle();

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('status', {
            'running': true,
            'byShell': true,
          }),
        ),
        (_) {},
      );
      await settle();

      expect(seen.map((status) => status.running).toList(), [true]);
      expect(seen.first.byShell, isTrue);
      expect(core.isRunning, isTrue);
    });
  });
}
