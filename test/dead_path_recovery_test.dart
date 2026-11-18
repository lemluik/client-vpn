import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/path_probe.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/provider.dart';
import 'package:client_vpn/reconnect.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Вымышленные узлы: адрес тестовый (`example.test`), ключи не боевые.
String vlessLink(int index, int port, String name) =>
    'vless://2f6bd5a1-1e73-4b1a-9d3c-00000000000$index@example.test:$port'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.test'
    '&flow=xtls-rprx-vision#$name';

const subscriptionUrl = 'https://example.test/sub';

/// Ядро, которое пишет конфиги запусков и ловит параллельные операции:
/// восстановление обязано быть последовательным, без одновременных
/// start/stop (аудит 03.11.2026, «лестница восстановления»).
class RecordingCore implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<CoreStatus> _status =
      StreamController<CoreStatus>.broadcast();

  final List<VpnConfig> startedWith = [];
  int startCalls = 0;
  int stopCalls = 0;

  /// Сколько раз одна операция застала другую незавершённой.
  int overlaps = 0;
  bool _inOperation = false;
  bool _running = false;

  Future<void> _guard(Future<void> Function() body) async {
    if (_inOperation) overlaps++;
    _inOperation = true;
    try {
      // Небольшая задержка расширяет окно, в котором видна гонка.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await body();
    } finally {
      _inOperation = false;
    }
  }

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
  Future<void> start(VpnConfig config) => _guard(() async {
    startCalls++;
    startedWith.add(config);
    _running = true;
    _status.add(const CoreStatus(true));
  });

  @override
  Future<void> stop() => _guard(() async {
    stopCalls++;
    _running = false;
    _status.add(const CoreStatus(false));
  });

  /// Ядро умерло само: приложение этого не просило.
  void kill() {
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

/// Проба пути, которой тест отвечает сам: заход висит, пока его не отпустят.
class GateAttempt {
  final List<Completer<bool>> _gates = [];

  int get calls => _calls;
  int _calls = 0;

  Future<bool> call(Uri endpoint) {
    _calls++;
    final gate = Completer<bool>();
    _gates.add(gate);
    return gate.future;
  }

  Future<void> nextCall() async {
    while (_gates.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  void release(bool alive) => _gates.removeAt(0).complete(alive);

  /// Отвечает на ближайший заход и ждёт следующего.
  Future<void> answer(bool alive) async {
    await nextCall();
    release(alive);
    await nextCall();
  }

  /// Отпускает все зависшие заходы: после перезапуска пробы старый ответ
  /// принадлежит прежнему запуску, и тест не выбирает его вручную.
  void releaseAll(bool alive) {
    for (final gate in List<Completer<bool>>.of(_gates)) {
      gate.complete(alive);
    }
    _gates.clear();
  }
}

class Harness {
  Harness({
    required this.state,
    required this.core,
    required this.gate,
    required this.store,
    required this.networks,
  });

  final AppState state;
  final RecordingCore core;
  final GateAttempt gate;
  final ProfileStore store;
  final StreamController<List<ConnectivityResult>> networks;
}

/// Состояние с короткой лестницей и управляемой пробой пути: испытание не
/// ждёт реальные минуты и не ходит в сеть.
Future<Harness> harness({required SubscriptionFetcher fetch}) async {
  SharedPreferences.setMockInitialValues({});
  final store = await ProfileStore.open();
  final added = await store.addSubscription(subscriptionUrl, fetch: fetch);
  await store.setActive(added.profile!.id);

  final gate = GateAttempt();
  final core = RecordingCore();
  final networks = StreamController<List<ConnectivityResult>>();
  final state = AppState(
    store,
    core,
    settings: await SettingsStore.open(),
    configWriter: (config) async => config,
    reconnect: ReconnectPlan(
      pauses: const [
        Duration(milliseconds: 150),
        Duration(milliseconds: 300),
        Duration(milliseconds: 600),
      ],
      probeInterval: const Duration(seconds: 5),
    ),
    pathProbe: PathProbe(
      attempt: gate.call,
      reachesCore: () => true,
      retry: const Duration(milliseconds: 5),
      deadRetry: const Duration(milliseconds: 5),
      failuresBeforeDead: 2,
    ),
    subscriptionFetch: fetch,
    networks: networks.stream,
  );
  return Harness(
    state: state,
    core: core,
    gate: gate,
    store: store,
    networks: networks,
  );
}

Future<void> settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('мёртвый путь при живом ядре (Ф1)', () {
    test('процесс жив, выходы мертвы — восстановление применяет новый конфиг',
        () async {
      var fetchCalls = 0;
      final h = await harness(
        fetch: (url) async {
          fetchCalls++;
          return SubscriptionResponse(
            body: fetchCalls == 1
                ? vlessLink(1, 443, 'Alpha')
                : vlessLink(2, 8443, 'Beta'),
          );
        },
      );
      addTearDown(h.state.dispose);
      h.networks.add([ConnectivityResult.wifi]);

      await h.state.connect();
      expect(h.state.state, TunnelState.on);
      expect(h.core.startCalls, 1);
      expect(fetchCalls, 1);

      // Устойчивый отказ пути: два провала пробы подряд.
      await h.gate.answer(false);
      await h.gate.answer(false);
      expect(h.state.pathState, PathState.dead);

      // Лестница обязана сработать без смерти процесса: принудительный
      // fetch, перезапуск и применение нового конфига.
      await settle(400);
      expect(fetchCalls, 2, reason: 'аварийный fetch выполнен');
      expect(h.core.stopCalls, 1);
      expect(h.core.startCalls, 2);
      expect(h.core.overlaps, 0);
      final applied = jsonEncode(jsonDecode(h.core.startedWith.last.json));
      expect(applied, contains('8443'), reason: 'новый конфиг применён');
      expect(h.state.log, anyElement(contains('Подписка обновлена аварийно')));

      // Лестница гаснет только после сквозного подтверждения пути.
      h.gate.releaseAll(true);
      await settle(50);
      expect(h.state.pathState, PathState.live);
      expect(h.state.reconnectStep, 0);
      expect(h.state.isReconnecting, isFalse);
    });

    test('одиночный провал контрольного адреса не порождает рестарт',
        () async {
      var fetchCalls = 0;
      final h = await harness(
        fetch: (url) async {
          fetchCalls++;
          return SubscriptionResponse(body: vlessLink(1, 443, 'Alpha'));
        },
      );
      addTearDown(h.state.dispose);
      h.networks.add([ConnectivityResult.wifi]);

      await h.state.connect();
      await h.gate.answer(false);
      await settle(300);

      expect(h.state.pathState, isNot(PathState.dead));
      expect(h.core.startCalls, 1, reason: 'транзиентный сбой не лечится рестартом');
      expect(fetchCalls, 1);
    });
  });

  group('аварийное обновление подписки (Ф2)', () {
    test('подписка обновлена минуту назад, затем отказ — fetch выполняется',
        () async {
      var fetchCalls = 0;
      final h = await harness(
        fetch: (url) async {
          fetchCalls++;
          return SubscriptionResponse(body: vlessLink(1, 443, 'Alpha'));
        },
      );
      addTearDown(h.state.dispose);
      h.networks.add([ConnectivityResult.wifi]);

      await h.state.connect();
      expect(fetchCalls, 1);
      // Обычному интервалу ещё не пора: refreshDue ничего бы не обновил.
      expect(h.store.providers.single.needsUpdate(DateTime.now()), isFalse);

      h.core.kill();
      await settle(300);

      expect(fetchCalls, 2, reason: 'аварийная попытка действительно сделала fetch');
      expect(h.state.log, contains('Перечитываем подписку после сбоя'));
      expect(h.core.startCalls, 2);
      expect(h.core.overlaps, 0);
    });

    test('ошибка fetch — рабочий кэш сохранён, backoff соблюдён', () async {
      var fetchCalls = 0;
      final moments = <DateTime>[];
      final h = await harness(
        fetch: (url) async {
          fetchCalls++;
          moments.add(DateTime.now());
          if (fetchCalls == 1) {
            return SubscriptionResponse(body: vlessLink(1, 443, 'Alpha'));
          }
          throw const SocketException('нет связи');
        },
      );
      addTearDown(h.state.dispose);
      h.networks.add([ConnectivityResult.wifi]);

      await h.state.connect();
      h.core.kill();
      await settle(280);

      expect(fetchCalls, 2);
      expect(h.state.log, contains('[ERR] Нет связи с провайдером'));
      // Кэш пережил сбой: профиль и конфиг строятся из прежних ссылок.
      expect(h.store.providers.single.links, hasLength(1));
      expect(h.store.active!.links, hasLength(1));
      expect(h.core.startCalls, 2);
      expect(
        jsonEncode(jsonDecode(h.core.startedWith.last.json)),
        contains('443'),
      );

      h.core.kill();
      await settle(500);
      expect(fetchCalls, 3);
      // Пауза второй попытки длиннее первой: лестница 150 → 300 мс.
      final first = moments[1].difference(moments[0]);
      final second = moments[2].difference(moments[1]);
      expect(second, greaterThan(first));
      expect(h.core.overlaps, 0);
    });
  });

  group('отмена восстановления пользователем', () {
    test('отключение во время аварийного refresh — VPN обратно не включился',
        () async {
      var fetchCalls = 0;
      final gate = Completer<SubscriptionResponse>();
      final h = await harness(
        fetch: (url) async {
          fetchCalls++;
          if (fetchCalls == 1) {
            return SubscriptionResponse(body: vlessLink(1, 443, 'Alpha'));
          }
          return gate.future;
        },
      );
      addTearDown(h.state.dispose);
      h.networks.add([ConnectivityResult.wifi]);

      await h.state.connect();
      h.core.kill();

      // Дожидаемся, пока аварийный fetch зависнет в пути.
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (fetchCalls < 2 && DateTime.now().isBefore(deadline)) {
        await settle(10);
      }
      expect(fetchCalls, 2);

      await h.state.disconnect();
      // Поздний ответ отменённой операции возвращается уже после отключения.
      gate.complete(SubscriptionResponse(body: vlessLink(2, 8443, 'Beta')));
      await settle(400);

      expect(h.state.state, TunnelState.off);
      expect(h.core.startCalls, 1, reason: 'туннель не поднялся обратно');
      expect(h.core.stopCalls, 1, reason: 'единственный stop — отключение');
      expect(h.state.isReconnecting, isFalse);
    });
  });

  group('две причины reconnect одновременно', () {
    test('смена сети и смерть ядра дают один путь восстановления', () async {
      var fetchCalls = 0;
      final h = await harness(
        fetch: (url) async {
          fetchCalls++;
          return SubscriptionResponse(body: vlessLink(1, 443, 'Alpha'));
        },
      );
      addTearDown(h.state.dispose);
      h.networks.add([ConnectivityResult.wifi]);

      await h.state.connect();
      expect(h.core.startCalls, 1);

      // Почти одновременно: сменилась сеть и умерло ядро.
      h.networks.add([ConnectivityResult.mobile]);
      h.core.kill();

      await settle(300);
      // Восстановление одно: лестница, а не второй параллельный путь.
      expect(h.core.startCalls, 2);
      expect(fetchCalls, 2);
      expect(h.core.overlaps, 0);

      // Переподъём по смене сети приходит позже (окно networkSettle, 2 с)
      // и тоже выполняется последовательно.
      await settle(2300);
      expect(h.state.state, TunnelState.on);
      expect(h.core.startCalls, 3);
      expect(h.core.overlaps, 0);
      expect(h.state.log, contains('Сеть сменилась — туннель поднимается заново'));
    });
  });
}
