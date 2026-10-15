import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const link = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

/// Ядро, которое считает подъёмы и падения: по ним проверяется переподъём.
class CountingCore implements VpnCore {
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

  @override
  Future<void> dispose() async {}

  @override
  Future<void> recoverAfterCrash() async {}
}

/// Состояние со слушателем сети: события подаёт тест, а не настоящий адаптер.
Future<(AppState, StreamController<List<ConnectivityResult>>)> watched(
  CountingCore core,
) async {
  SharedPreferences.setMockInitialValues({});
  final store = await ProfileStore.open();
  final profile = await store.addLinks(
    name: '',
    links: parseLinks(link).links,
  );
  await store.setActive(profile.id);

  final controller = StreamController<List<ConnectivityResult>>();
  final state = AppState(
    store,
    core,
    // Служебный конфиг на диске проверен отдельно в temp_config_test.
    configWriter: (config) async => config,
    networks: controller.stream,
  );
  addTearDown(state.dispose);
  addTearDown(controller.close);
  return (state, controller);
}

Future<void> _waitSettle() => Future<void>.delayed(
    AppState.networkSettle + const Duration(milliseconds: 300));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('подпись сети', () {
    test('собственный туннель не считается сменой сети', () {
      expect(
        networkKey([ConnectivityResult.wifi, ConnectivityResult.vpn]),
        'wifi',
      );
    });

    test('несколько сетей входят в подпись по алфавиту', () {
      expect(
        networkKey([ConnectivityResult.wifi, ConnectivityResult.mobile]),
        'mobile,wifi',
      );
      expect(
        networkKey([ConnectivityResult.mobile, ConnectivityResult.wifi]),
        'mobile,wifi',
      );
    });

    test('пропажа связи — пустая подпись', () {
      expect(networkKey([ConnectivityResult.none]), '');
      expect(networkKey(const []), '');
    });
  });

  group('переподъём туннеля при смене сети', () {
    test('Wi-Fi на LTE: туннель падает и поднимается сам', () async {
      final core = CountingCore();
      final (state, networks) = await watched(core);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      expect(core.startCalls, 1);

      networks.add([ConnectivityResult.mobile]);
      await _waitSettle();

      expect(core.startCalls, 2);
      expect(core.stopCalls, 1);
      expect(state.state, TunnelState.on);
      expect(
        state.log,
        contains('Сеть сменилась — туннель поднимается заново'),
      );
    });

    test('первое событие сети туннель не трогает', () async {
      final core = CountingCore();
      final (state, networks) = await watched(core);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      await _waitSettle();

      expect(core.startCalls, 1);
      expect(core.stopCalls, 0);
    });

    test('повтор того же соединения не перезапускает туннель', () async {
      final core = CountingCore();
      final (state, networks) = await watched(core);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      networks.add([ConnectivityResult.wifi]);
      await _waitSettle();

      expect(core.startCalls, 1);
      expect(core.stopCalls, 0);
    });

    test('пропажа сети туннель не перезапускает: поднимать некуда', () async {
      final core = CountingCore();
      final (state, networks) = await watched(core);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();
      networks.add([ConnectivityResult.none]);
      await _waitSettle();

      expect(core.startCalls, 1);
      expect(core.stopCalls, 0);
    });

    test('выключенный туннель смена сети не поднимает', () async {
      final core = CountingCore();
      final (state, networks) = await watched(core);

      networks.add([ConnectivityResult.wifi]);
      networks.add([ConnectivityResult.mobile]);
      await _waitSettle();

      expect(core.startCalls, 0);
      expect(state.state, TunnelState.off);
    });

    test('серия событий за время успокоения даёт один переподъём', () async {
      final core = CountingCore();
      final (state, networks) = await watched(core);

      networks.add([ConnectivityResult.wifi]);
      await state.connect();

      networks.add([ConnectivityResult.none]);
      networks.add([ConnectivityResult.mobile]);
      networks.add([ConnectivityResult.wifi, ConnectivityResult.mobile]);
      await _waitSettle();

      expect(core.startCalls, 2);
      expect(core.stopCalls, 1);
    });
  });
}
