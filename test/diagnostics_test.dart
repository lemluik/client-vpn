import 'dart:async';
import 'dart:io';

import 'package:client_vpn/app_proxy.dart';
import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/diagnostics.dart';
import 'package:client_vpn/path_probe.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/reconnect.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/provider.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Контрольные адреса по умолчанию (метки A/B): проба различает их по имени.
bool _isA(Uri uri) => uri.host.contains('gstatic');

const _facts = DiagFacts(
  appVersion: '0.4.3',
  coreVersion: '26.3.27',
  platform: 'android',
  osVersion: '13',
  networkType: 'wifi',
);

/// Управляемое окружение диагностики: сеть не поднимается, ответы задаёт тест.
class FakeEnv {
  FakeEnv({
    this.reachesCore = true,
    this.networkOk = true,
    this.subscriptionOk = true,
    this.coreOk = true,
    List<EntryCandidate>? entries,
    EntryCandidate? current,
    ProbeOutcome Function(Uri uri, bool viaTunnel, String key)? probe,
    this.budget = const DiagnosticsBudget(),
  }) : entries = entries ?? [const EntryCandidate('alpha', 'Alpha')],
       current = current ?? const EntryCandidate('alpha', 'Alpha'),
       activeKey = (current ?? const EntryCandidate('alpha', 'Alpha')).key,
       probeFn = probe ?? ((uri, viaTunnel, key) => const ProbeOutcome(statusCode: 204));

  bool reachesCore;
  bool networkOk;
  bool subscriptionOk;
  bool coreOk;
  final List<EntryCandidate> entries;
  EntryCandidate? current;
  String activeKey;
  final ProbeOutcome Function(Uri, bool, String) probeFn;
  final DiagnosticsBudget budget;

  final List<String> switches = [];
  bool restoreCalled = false;
  bool cancelledFlag = false;
  int probeCalls = 0;

  DiagnosticsEnv env() => DiagnosticsEnv(
    facts: () => _facts,
    reachesCore: () => reachesCore,
    probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) async {
      probeCalls++;
      return probeFn(uri, viaTunnel, activeKey);
    },
    checkNetwork: () async => StageResult(
      DiagStage.network,
      networkOk,
      networkOk ? 'сеть доступна' : 'нет сети',
    ),
    checkSubscription: () async => StageResult(
      DiagStage.subscription,
      subscriptionOk,
      subscriptionOk ? 'подписка загружена' : 'нет подключения',
    ),
    checkCore: () async => StageResult(
      DiagStage.core,
      coreOk,
      coreOk ? 'ядро запущено' : 'ядро не работает',
    ),
    entries: () => entries,
    currentEntry: () => current,
    switchTo: (target) async {
      switches.add(target.key);
      activeKey = target.key;
    },
    restore: () async => restoreCalled = true,
    cancelled: () => cancelledFlag,
  );

  ConnectionDiagnostics runner() =>
      ConnectionDiagnostics(env: env(), budget: budget);
}

/// Ответ через туннель мёртв, напрямую адрес доступен — отказ доказан.
ProbeOutcome _deadTunnelLiveDirect(Uri uri, bool viaTunnel, String key) =>
    viaTunnel
    ? const ProbeOutcome(failure: ProbeFailure.timeout)
    : const ProbeOutcome(statusCode: 204);

void main() {
  group('классификация пробы: TCP доступен, HTTP не проходит', () {
    test('обычный 204 проходит пробу', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final outcome = await tunnelControlProbe(
        Uri.parse('http://127.0.0.1:${server.port}/generate_204'),
        viaTunnel: false,
      );

      expect(outcome.statusCode, 204);
      expect(outcome.failure, ProbeFailure.none);
      expect(outcome.responded, isTrue);
    });

    test('TCP принят, но HTTP-обмен не состоялся — не успех и не отказ порта',
        () async {
      // Сервер принимает соединение и сразу рвёт его: TCP доступен, HTTP не идёт.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      server.listen((socket) => socket.destroy());

      final outcome = await tunnelControlProbe(
        Uri.parse('http://127.0.0.1:${server.port}/generate_204'),
        viaTunnel: false,
        timeout: const Duration(seconds: 2),
      );

      expect(outcome.statusCode, isNull);
      expect(outcome.responded, isFalse);
      expect(outcome.failure, isNot(ProbeFailure.refused));
      expect(outcome.failure, isNot(ProbeFailure.none));
    });

    test('закрытый порт — отказ соединения (вход недоступен)', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      // Срок заведомо больше задержки отказа ОС на loopback: иначе общий
      // таймаут пробы обгоняет отказ соединения и маскирует его класс.
      final outcome = await tunnelControlProbe(
        Uri.parse('http://127.0.0.1:$port/generate_204'),
        viaTunnel: false,
        timeout: const Duration(seconds: 6),
      );

      expect(outcome.statusCode, isNull);
      expect(outcome.failure, ProbeFailure.refused);
    });

    test('неожидаемый код ответа — обмен был, но успехом туннеля не считается',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/generate_204');

      final outcome = await tunnelControlProbe(uri, viaTunnel: false);
      final control = ControlEndpoint('A', Uri.parse('http://x/204'), const {204});

      expect(outcome.statusCode, 500);
      expect(outcome.responded, isTrue);
      expect(control.matches(outcome.statusCode), isFalse);
    });

    test('зависшее тело обрывается общим сроком, проба провалена', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('заголовки пришли, тело не закончено');
        await request.response.flush();
      });

      final watch = Stopwatch()..start();
      final outcome = await tunnelControlProbe(
        Uri.parse('http://127.0.0.1:${server.port}/generate_204'),
        viaTunnel: false,
        timeout: const Duration(milliseconds: 300),
      );
      watch.stop();

      expect(outcome.failure, ProbeFailure.timeout);
      expect(outcome.statusCode, isNull);
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });
  });

  group('три состояния итога', () {
    test('живое ядро, мёртвый путь — отказ подтверждён', () async {
      final fake = FakeEnv(probe: _deadTunnelLiveDirect);
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.failureConfirmed);
      expect(report.entries.single.verdict, DiagVerdict.failureConfirmed);
      expect(report.entries.single.note, contains('напрямую'));
      expect(report.summary(), contains('Отказ подтверждён'));
    });

    test('ожидаемый ответ через туннель — работает', () async {
      final fake = FakeEnv();
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.works);
      expect(report.summary(), 'Соединение работает');
      expect(report.entries.single.controls, {'A': 204, 'B': 204});
    });

    test('отказ одного контрольного сайта — всё равно работает', () async {
      final fake = FakeEnv(
        probe: (uri, viaTunnel, key) => _isA(uri)
            ? const ProbeOutcome(statusCode: 204)
            : const ProbeOutcome(failure: ProbeFailure.timeout),
      );
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.works);
      expect(report.entries.single.controls, {'A': 204, 'B': null});
      expect(report.entries.single.note, contains('один контрольный адрес'));
    });

    test('контрольные адреса недоступны и напрямую — не удалось проверить',
        () async {
      final fake = FakeEnv(
        probe: (uri, viaTunnel, key) =>
            const ProbeOutcome(failure: ProbeFailure.timeout),
      );
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.unknown);
      expect(report.entries.single.note, contains('не доказан'));
      expect(report.summary(), 'Не удалось проверить соединение');
    });

    test('нет входа через ядро — не удалось проверить, проба не звалась',
        () async {
      final fake = FakeEnv(reachesCore: false);
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.unknown);
      expect(fake.probeCalls, 0);
      expect(report.entries.single.note, contains('нет входа через ядро'));
    });

    test('отказ этапа сети — отказ подтверждён, путь не проверяется', () async {
      final fake = FakeEnv(networkOk: false);
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.failureConfirmed);
      expect(report.entries, isEmpty);
      expect(fake.probeCalls, 0);
    });

    test('прямой обход не подменяет туннель: успех только через ядро', () async {
      // Напрямую 204, через туннель ответа нет — это отказ, а не «работает».
      final fake = FakeEnv(
        probe: (uri, viaTunnel, key) => viaTunnel
            ? const ProbeOutcome(failure: ProbeFailure.timeout)
            : const ProbeOutcome(statusCode: 204),
      );
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.failureConfirmed);
    });
  });

  group('активный тест переключения входа', () {
    test('каждый вход отдельно, исходный вход возвращается', () async {
      final fake = FakeEnv(
        entries: const [
          EntryCandidate('alpha', 'Alpha'),
          EntryCandidate('beta', 'Beta'),
          EntryCandidate('gamma', 'Gamma'),
        ],
        current: const EntryCandidate('alpha', 'Alpha'),
        probe: (uri, viaTunnel, key) {
          if (key == 'beta') return const ProbeOutcome(statusCode: 204);
          if (key == 'gamma') {
            return viaTunnel
                ? const ProbeOutcome(failure: ProbeFailure.timeout)
                : const ProbeOutcome(statusCode: 204);
          }
          return const ProbeOutcome(failure: ProbeFailure.timeout);
        },
      );
      final report = await fake.runner().checkAllEntries();

      expect(report.switchTested, isTrue);
      expect(report.entries, hasLength(3));
      expect(report.verdict, DiagVerdict.works, reason: 'один живой вход — работает');
      expect(report.entries[1].verdict, DiagVerdict.works);
      expect(report.entries[2].verdict, DiagVerdict.failureConfirmed);
      expect(report.entries[1].recovery, isNotNull);
      // Исходный вход возвращён последним переключением.
      expect(fake.switches, ['alpha', 'beta', 'gamma', 'alpha']);
      expect(fake.restoreCalled, isTrue);
    });

    test('недоступный вход не валит итог, если другой работает', () async {
      final fake = FakeEnv(
        entries: const [
          EntryCandidate('alpha', 'Alpha'),
          EntryCandidate('beta', 'Beta'),
        ],
        probe: (uri, viaTunnel, key) => key == 'beta'
            ? const ProbeOutcome(statusCode: 204)
            : _deadTunnelLiveDirect(uri, viaTunnel, key),
      );
      final report = await fake.runner().checkAllEntries();

      expect(report.entries.first.verdict, DiagVerdict.failureConfirmed);
      expect(report.verdict, DiagVerdict.works);
    });

    test('все входы мертвы — отказ подтверждён', () async {
      final fake = FakeEnv(
        entries: const [
          EntryCandidate('alpha', 'Alpha'),
          EntryCandidate('beta', 'Beta'),
        ],
        probe: _deadTunnelLiveDirect,
      );
      final report = await fake.runner().checkAllEntries();

      expect(report.verdict, DiagVerdict.failureConfirmed);
      expect(report.entries.every((e) => e.verdict == DiagVerdict.failureConfirmed),
          isTrue);
    });

    test('бюджет ограничивает число проверяемых входов', () async {
      final fake = FakeEnv(
        entries: const [
          EntryCandidate('a', 'A'),
          EntryCandidate('b', 'B'),
          EntryCandidate('c', 'C'),
          EntryCandidate('d', 'D'),
        ],
        budget: const DiagnosticsBudget(maxEntries: 2),
      );
      final report = await fake.runner().checkAllEntries();

      expect(report.entries, hasLength(2));
    });

    test('отмена во время теста — исходный вход не переподнимается', () async {
      late final FakeEnv fake;
      fake = FakeEnv(
        entries: const [
          EntryCandidate('alpha', 'Alpha'),
          EntryCandidate('beta', 'Beta'),
        ],
        // Исходный вход отличен от первого проверяемого: возврат именно его
        // и должен быть пропущен после отключения пользователя.
        current: const EntryCandidate('beta', 'Beta'),
        probe: (uri, viaTunnel, key) {
          // После первого входа пользователь отключился.
          fake.cancelledFlag = true;
          return const ProbeOutcome(statusCode: 204);
        },
      );
      final report = await fake.runner().checkAllEntries();

      expect(report.cancelled, isTrue);
      expect(report.summary(), contains('прервана'));
      expect(fake.restoreCalled, isTrue);
      // Возврат исходного входа пропущен: пользователь отключился сам.
      expect(fake.switches, isNot(contains('beta')));
    });
  });

  group('очистка секретов в отчёте', () {
    test('адреса, ключи, UUID и ссылки маскируются перед отправкой', () {
      const secretKey = 'SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234';
      const uuid = '2f6bd5a1-1e73-4b1a-9d3c-000000000001';
      final report = DiagnosticsReport(
        facts: _facts,
        stages: const [
          StageResult(
            DiagStage.network,
            true,
            'узел 203.0.113.7 id $uuid ключ $secretKey '
                'ссылка vless://$uuid@example.test:443',
          ),
        ],
        entries: const [
          EntryResult(
            entry: EntryCandidate('alpha', 'Alpha'),
            verdict: DiagVerdict.works,
            stage: DiagStage.path,
            controls: {'A': 204},
            note: 'адрес 10.0.0.1',
          ),
        ],
        verdict: DiagVerdict.works,
        startedAt: DateTime(2026, 11, 13),
      );

      final text = report.toShareText();

      expect(text, contains('[адрес]'));
      expect(text, contains('[ключ]'));
      expect(text, contains('[идентификатор]'));
      expect(text, contains('[ссылка]'));
      expect(text, isNot(contains('203.0.113.7')));
      expect(text, isNot(contains('10.0.0.1')));
      expect(text, isNot(contains(uuid)));
      expect(text, isNot(contains(secretKey)));
      expect(text, isNot(contains('vless://')));
      // Не секретное остаётся: имя региона и код контрольного адреса.
      expect(text, contains('Alpha'));
      expect(text, contains('204'));
    });
  });

  group('AppState: смена сети и отключение пользователем', () {
    test('смена сети: диагностика видит отсутствие сети, затем восстановление',
        () async {
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) async =>
            const ProbeOutcome(statusCode: 204),
      );
      addTearDown(h.state.dispose);
      h.networks.add([ConnectivityResult.wifi]);
      await h.state.connect();
      expect(h.state.state, TunnelState.on);

      h.networks.add([ConnectivityResult.none]);
      await _settle(50);
      expect(h.state.state, TunnelState.noLink);

      await h.state.runDiagnostics();
      final report = h.state.diagnostics!;
      expect(report.verdict, DiagVerdict.failureConfirmed);
      expect(report.stages.first.stage, DiagStage.network);
      expect(report.stages.first.ok, isFalse);
      expect(report.stages.first.detail, 'нет сети');

      h.networks.add([ConnectivityResult.wifi]);
      await _settle(2300);
      expect(h.state.state, TunnelState.on);
    });

    test('отключение во время активного теста — отчёт прерван, туннель не поднят',
        () async {
      final gate = Completer<ProbeOutcome>();
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) =>
            gate.future,
      );
      addTearDown(h.state.dispose);
      // Собственный трафик приложения идёт через ядро: путь проверяем.
      AppProxy.attach((protocol: 'http', port: 10809));
      addTearDown(() => AppProxy.attach(null));

      h.networks.add([ConnectivityResult.wifi]);
      await h.state.connect();
      expect(h.state.state, TunnelState.on);

      final run = h.state.runDiagnostics(switchEntries: true);
      await _settle(60);
      expect(h.state.isDiagnosticsRunning, isTrue);

      await h.state.disconnect();
      gate.complete(const ProbeOutcome(statusCode: 204));
      await run;

      final report = h.state.diagnostics!;
      expect(report.cancelled, isTrue);
      expect(report.summary(), contains('прервана'));
      expect(h.state.state, TunnelState.off);
      expect(h.core.startCalls, 1, reason: 'туннель не поднялся обратно');
    });

    test('автодиагностика запускается один раз на эпизод мёртвого пути',
        () async {
      var probeCalls = 0;
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) async {
          probeCalls++;
          return viaTunnel
              ? const ProbeOutcome(failure: ProbeFailure.timeout)
              : const ProbeOutcome(statusCode: 204);
        },
        pathAlive: false,
      );
      addTearDown(h.state.dispose);
      AppProxy.attach((protocol: 'http', port: 10809));
      addTearDown(() => AppProxy.attach(null));
      h.networks.add([ConnectivityResult.wifi]);

      await h.state.connect();
      // Проба пути объявляет путь мёртвым (два провала подряд).
      await _settle(120);
      expect(h.state.pathState, PathState.dead);

      final report = h.state.diagnostics;
      expect(report, isNotNull, reason: 'автодиагностика собрала отчёт');
      expect(report!.verdict, DiagVerdict.failureConfirmed);
      final callsAfterEpisode = probeCalls;
      expect(callsAfterEpisode, greaterThan(0));

      // Повторные события мёртвого пути не запускают диагностику снова.
      await _settle(120);
      expect(probeCalls, callsAfterEpisode);
    });
  });
}

/// Вымышленный узел: адрес тестовый, ключи не боевые.
String _vlessLink(int index, int port, String name) =>
    'vless://2f6bd5a1-1e73-4b1a-9d3c-00000000000$index@example.test:$port'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.test'
    '&flow=xtls-rprx-vision#$name';

const _subscriptionUrl = 'https://example.test/sub';

/// Ядро-заглушка: пишет запуски/остановки, не поднимает настоящий туннель.
class _Core implements VpnCore {
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
  @override
  Future<void> dispose() async {}
  @override
  Future<void> recoverAfterCrash() async {}
  @override
  Future<void> markTunnelFresh() async {}
  @override
  Future<bool> takePendingConnect() async => false;
}

class _Harness {
  _Harness(this.state, this.core, this.networks);
  final AppState state;
  final _Core core;
  final StreamController<List<ConnectivityResult>> networks;
}

Future<_Harness> _harness({
  required ControlProbe probe,
  bool pathAlive = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = await ProfileStore.open();
  Future<SubscriptionResponse> fetch(String url) async =>
      SubscriptionResponse(body: _vlessLink(1, 443, 'Alpha'));
  final added = await store.addSubscription(_subscriptionUrl, fetch: fetch);
  await store.setActive(added.profile!.id);

  final core = _Core();
  final networks = StreamController<List<ConnectivityResult>>();
  final state = AppState(
    store,
    core,
    settings: await SettingsStore.open(),
    configWriter: (config) async => config,
    reconnect: ReconnectPlan(
      pauses: const [Duration(milliseconds: 150)],
      probeInterval: const Duration(seconds: 5),
    ),
    pathProbe: PathProbe(
      attempt: (_) async => pathAlive,
      reachesCore: () => true,
      retry: const Duration(milliseconds: 5),
      deadRetry: const Duration(milliseconds: 5),
      failuresBeforeDead: 2,
    ),
    subscriptionFetch: fetch,
    diagnosticsProbe: probe,
    networks: networks.stream,
  );
  return _Harness(state, core, networks);
}

Future<void> _settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));