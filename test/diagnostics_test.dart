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
    FutureOr<ProbeOutcome> Function(Uri uri, bool viaTunnel, String key)? probe,
    this.budget = const DiagnosticsBudget(),
    this.cancelReasonFn,
    this.coreStateFn,
    this.fingerprintFn,
    this.networkTypeFn,
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
  final FutureOr<ProbeOutcome> Function(Uri, bool, String) probeFn;
  final DiagnosticsBudget budget;
  final DiagCancelReason? Function()? cancelReasonFn;
  final String Function()? coreStateFn;
  final String? Function()? fingerprintFn;
  final String Function()? networkTypeFn;

  final List<String> switches = [];
  bool restoreCalled = false;
  bool cancelledFlag = false;
  int probeCalls = 0;

  /// Последний срок, с которым окружение позвало пробу (проверка зажима).
  Duration? lastTimeout;

  DiagnosticsEnv env() => DiagnosticsEnv(
    facts: () => networkTypeFn == null
        ? _facts
        : DiagFacts(
            appVersion: _facts.appVersion,
            coreVersion: _facts.coreVersion,
            platform: _facts.platform,
            osVersion: _facts.osVersion,
            networkType: networkTypeFn!(),
          ),
    reachesCore: () => reachesCore,
    probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) async {
      probeCalls++;
      lastTimeout = timeout;
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
    cancelReason: cancelReasonFn,
    coreState: coreStateFn,
    configFingerprint: fingerprintFn,
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

  group('причина прерывания проверки', () {
    test('остановка ядра во время замера — названа ядром, не пользователем',
        () async {
      late final FakeEnv fake;
      fake = FakeEnv(
        probe: (uri, viaTunnel, key) {
          fake.cancelledFlag = true;
          return const ProbeOutcome(statusCode: 204);
        },
        cancelReasonFn: () =>
            fake.cancelledFlag ? DiagCancelReason.coreStopped : null,
      );
      final report = await fake.runner().checkCurrent();

      expect(report.cancelled, isTrue);
      expect(report.cancelReason, DiagCancelReason.coreStopped);
      expect(report.summary(), 'Проверка прервана: ядро остановилось');
      expect(
        report.toShareText(),
        contains('Причина прерывания: ядро остановилось во время проверки'),
      );
    });

    test('автоматическое переподключение — названо восстановлением', () async {
      late final FakeEnv fake;
      fake = FakeEnv(
        probe: (uri, viaTunnel, key) {
          fake.cancelledFlag = true;
          return const ProbeOutcome(statusCode: 204);
        },
        cancelReasonFn: () =>
            fake.cancelledFlag ? DiagCancelReason.recovery : null,
      );
      final report = await fake.runner().checkCurrent();

      expect(report.cancelled, isTrue);
      expect(report.cancelReason, DiagCancelReason.recovery);
      expect(
        report.summary(),
        'Проверка прервана: шло автоматическое переподключение',
      );
      expect(
        report.toShareText(),
        contains('Причина прерывания: шло автоматическое переподключение'),
      );
    });

    test('окружение без классификатора — отмена считается отключением',
        () async {
      late final FakeEnv fake;
      fake = FakeEnv(
        probe: (uri, viaTunnel, key) {
          fake.cancelledFlag = true;
          return const ProbeOutcome(statusCode: 204);
        },
      );
      final report = await fake.runner().checkCurrent();

      expect(report.cancelled, isTrue);
      expect(report.cancelReason, DiagCancelReason.user);
      expect(
        report.summary(),
        'Проверка прервана: соединение отключено пользователем',
      );
    });

    test('активный тест входов: причина доходит до отчёта', () async {
      late final FakeEnv fake;
      fake = FakeEnv(
        entries: const [
          EntryCandidate('alpha', 'Alpha'),
          EntryCandidate('beta', 'Beta'),
        ],
        probe: (uri, viaTunnel, key) {
          fake.cancelledFlag = true;
          return const ProbeOutcome(statusCode: 204);
        },
        cancelReasonFn: () =>
            fake.cancelledFlag ? DiagCancelReason.coreStopped : null,
      );
      final report = await fake.runner().checkAllEntries();

      expect(report.cancelled, isTrue);
      expect(report.cancelReason, DiagCancelReason.coreStopped);
      expect(report.summary(), contains('ядро остановилось'));
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
      expect(report.cancelReason, DiagCancelReason.user);
      expect(
        report.toShareText(),
        contains('Причина прерывания: пользователь отключил соединение'),
      );
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

    test('выключенный VPN: проверка не запускается, пустой отчёт не появляется',
        () async {
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) async =>
            const ProbeOutcome(statusCode: 204),
      );
      addTearDown(h.state.dispose);

      await h.state.runDiagnostics();

      expect(h.state.diagnostics, isNull);
      expect(h.state.isDiagnosticsRunning, isFalse);
    });

    test('ядро остановилось во время замера — причина «ядро», не пользователь',
        () async {
      final gate = Completer<ProbeOutcome>();
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) =>
            gate.future,
      );
      addTearDown(h.state.dispose);
      AppProxy.attach((protocol: 'http', port: 10809));
      addTearDown(() => AppProxy.attach(null));
      h.networks.add([ConnectivityResult.wifi]);
      await h.state.connect();

      final run = h.state.runDiagnostics();
      await _settle(60);
      expect(h.state.isDiagnosticsRunning, isTrue);

      // Обрыв со стороны ядра: приложение остановки не просило.
      await h.core.stop();
      gate.complete(const ProbeOutcome(statusCode: 204));
      await run;

      final report = h.state.diagnostics!;
      expect(report.cancelled, isTrue);
      expect(report.cancelReason, DiagCancelReason.coreStopped);
      expect(report.summary(), contains('ядро остановилось'));
      expect(
        report.toShareText(),
        contains('Причина прерывания: ядро остановилось во время проверки'),
      );
    });

    test('смена сети во время замера — причина «переподключение», туннель поднят',
        () async {
      final gate = Completer<ProbeOutcome>();
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) =>
            gate.future,
      );
      addTearDown(h.state.dispose);
      AppProxy.attach((protocol: 'http', port: 10809));
      addTearDown(() => AppProxy.attach(null));
      h.networks.add([ConnectivityResult.wifi]);
      await h.state.connect();

      final run = h.state.runDiagnostics();
      await _settle(60);
      expect(h.state.isDiagnosticsRunning, isTrue);

      // Автоматика меняет сеть: отключение не пользовательское.
      h.networks.add([ConnectivityResult.mobile]);
      await _settle(2300);
      gate.complete(const ProbeOutcome(statusCode: 204));
      await run;

      final report = h.state.diagnostics!;
      expect(report.cancelled, isTrue);
      expect(report.cancelReason, DiagCancelReason.recovery);
      expect(report.summary(), contains('автоматическое переподключение'));
      expect(h.state.state, TunnelState.on);
    });

    test('переподключение ждёт конца замера: ядро не останавливается посреди пробы',
        () async {
      final gate = Completer<ProbeOutcome>();
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) =>
            viaTunnel
            ? gate.future
            : Future.value(const ProbeOutcome(statusCode: 204)),
        pathAlive: false,
      );
      addTearDown(h.state.dispose);
      AppProxy.attach((protocol: 'http', port: 10809));
      addTearDown(() => AppProxy.attach(null));
      h.networks.add([ConnectivityResult.wifi]);
      await h.state.connect();
      // Замер начинается до объявления мёртвого пути: автодиагностика
      // не перехватывает пробу, очередь переподключения встаёт при замере.
      final run = h.state.runDiagnostics();

      // Пауза перечитывания подписки (150 мс) срабатывает во время замера.
      await _settle(300);
      expect(h.state.isDiagnosticsRunning, isTrue);
      expect(
        h.core.stopCalls,
        0,
        reason: 'перечитывание подписки отложено до конца замера',
      );

      gate.complete(const ProbeOutcome(failure: ProbeFailure.timeout));
      await run;

      final report = h.state.diagnostics!;
      expect(report.cancelled, isFalse);
      expect(report.verdict, DiagVerdict.failureConfirmed);
      expect(h.core.stopCalls, 0);
    });
  });

  group('этапы одной попытки', () {
    test('успешная проба расписана по этапам: прокси, TCP, TLS, HTTP', () async {
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
      expect(outcome.trace.map((s) => s.name).toList(),
          ['proxy', 'tcp', 'tls', 'http']);
      expect(outcome.trace.every((s) => s.ok), isTrue);
      expect(outcome.trace.first.note, 'напрямую, мимо ядра');
      expect(outcome.trace[2].note, 'не требуется: схема http');
      expect(outcome.trace.last.note, 'код ответа 204');
    });

    test('закрытый порт: этап TCP провален, код ошибки записан', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      final outcome = await tunnelControlProbe(
        Uri.parse('http://127.0.0.1:$port/generate_204'),
        viaTunnel: false,
        timeout: const Duration(seconds: 6),
      );

      expect(outcome.failure, ProbeFailure.refused);
      expect(outcome.trace.map((s) => s.name).toList(), ['proxy', 'tcp']);
      final tcp = outcome.trace.last;
      expect(tcp.ok, isFalse);
      expect(tcp.errorCode, isNotNull);
      expect(tcp.note, 'соединение не установлено');
    });

    test('TCP принят, обмен сорвался: провален именно этап HTTP', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      server.listen((socket) => socket.destroy());

      final outcome = await tunnelControlProbe(
        Uri.parse('http://127.0.0.1:${server.port}/generate_204'),
        viaTunnel: false,
        timeout: const Duration(seconds: 2),
      );

      final tcp = outcome.trace.firstWhere((s) => s.name == 'tcp');
      expect(tcp.ok, isTrue, reason: 'соединение было принято');
      final http = outcome.trace.last;
      expect(http.name, 'http');
      expect(http.ok, isFalse);
      expect(outcome.failure, isNot(ProbeFailure.refused));
    });

    test('зависшее тело: последний этап — общий срок, а не вечное ожидание',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('заголовки пришли, тело не закончено');
        await request.response.flush();
      });

      final outcome = await tunnelControlProbe(
        Uri.parse('http://127.0.0.1:${server.port}/generate_204'),
        viaTunnel: false,
        timeout: const Duration(milliseconds: 300),
      );

      expect(outcome.failure, ProbeFailure.timeout);
      expect(outcome.trace.last.name, 'deadline');
      expect(outcome.trace.last.ok, isFalse);
      expect(outcome.trace.last.note, 'общий срок пробы истёк');
    });

    test('через туннель: обмен идёт через локальный вход ядра абсолютным запросом',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? seenTarget;
      server.listen((request) async {
        seenTarget = request.uri.toString();
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });
      AppProxy.attach((protocol: 'http', port: server.port));
      addTearDown(() => AppProxy.attach(null));

      final outcome = await tunnelControlProbe(
        Uri.parse('http://example.test/generate_204'),
        viaTunnel: true,
      );

      expect(outcome.statusCode, 204);
      expect(seenTarget, 'http://example.test/generate_204',
          reason: 'прокси получает абсолютную форму запроса');
      expect(outcome.trace.first.note, 'локальный http-вход, порт ${server.port}');
      expect(outcome.trace[1].note, 'соединение с локальным прокси');
    });
  });

  group('контекст попыток в отчёте', () {
    test('попытка несёт состояние ядра, сеть и отпечаток конфига', () async {
      final fake = FakeEnv(
        coreStateFn: () => 'работает',
        fingerprintFn: () => 'ab12cd34',
        probe: (uri, viaTunnel, key) => const ProbeOutcome(
          statusCode: 204,
          elapsed: Duration(milliseconds: 9),
          trace: [
            ProbeStage(name: 'tcp', ok: true, elapsed: Duration(milliseconds: 7)),
          ],
        ),
      );
      final report = await fake.runner().checkCurrent();

      final attempts = report.entries.single.attempts;
      expect(attempts.length, 2);
      expect(attempts.first.coreState, 'работает');
      expect(attempts.first.networkType, 'wifi');
      expect(attempts.first.configFingerprint, 'ab12cd34');
      final text = report.toShareText();
      expect(text, contains('ядро: работает; сеть: wifi; конфиг: ab12cd34'));
      expect(text, contains('tcp: ок (7 мс)'));
      expect(text, contains('попытка A (через туннель): 204'));
    });

    test('смена сети между попытками видна в отчёте', () async {
      var network = 'wifi';
      final fake = FakeEnv(
        networkTypeFn: () => network,
        probe: (uri, viaTunnel, key) {
          if (!viaTunnel) network = 'mobile';
          return viaTunnel
              ? const ProbeOutcome(failure: ProbeFailure.timeout)
              : const ProbeOutcome(statusCode: 204);
        },
      );
      final report = await fake.runner().checkCurrent();

      expect(report.verdict, DiagVerdict.failureConfirmed);
      final entry = report.entries.single;
      expect(entry.networkChanged, isTrue);
      expect(entry.attempts.first.networkType, 'wifi');
      expect(entry.attempts.last.networkType, 'mobile');
      expect(entry.attempts.last.label, 'A напрямую');
      expect(report.toShareText(), contains('сеть менялась во время проверки'));
    });
  });

  group('общий срок диагностики', () {
    test('зависшая проба обрывается бюджетом, отчёт неполный, проверка завершена',
        () async {
      final gate = Completer<ProbeOutcome>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(const ProbeOutcome());
      });
      final fake = FakeEnv(
        probe: (uri, viaTunnel, key) => gate.future,
        budget: const DiagnosticsBudget(
          total: Duration(milliseconds: 150),
          probeTimeout: Duration(milliseconds: 80),
        ),
      );

      final watch = Stopwatch()..start();
      final report = await fake.runner().checkCurrent().timeout(
            const Duration(seconds: 5),
          );
      watch.stop();

      expect(watch.elapsedMilliseconds, lessThan(3000));
      expect(report.budgetExceeded, isTrue);
      expect(report.verdict, DiagVerdict.unknown);
      expect(fake.probeCalls, 1,
          reason: 'после исчерпания срока новые пробы не начинаются');
      expect(report.toShareText(), contains('Срок проверки исчерпан'));
    });

    test('срок одной пробы зажат остатком бюджета и её собственным пределом',
        () async {
      final tight = FakeEnv(
        budget: const DiagnosticsBudget(total: Duration(milliseconds: 200)),
      );
      await tight.runner().checkCurrent();
      expect(tight.lastTimeout, isNotNull);
      expect(tight.lastTimeout!, lessThanOrEqualTo(const Duration(milliseconds: 200)));

      final normal = FakeEnv();
      await normal.runner().checkCurrent();
      expect(normal.lastTimeout, const Duration(seconds: 6));
    });

    test('AppState: зависшая диагностика завершается и снимает блокировку',
        () async {
      final gate = Completer<ProbeOutcome>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(const ProbeOutcome());
      });
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) =>
            gate.future,
        diagnosticsBudget: const DiagnosticsBudget(
          total: Duration(milliseconds: 150),
          probeTimeout: Duration(milliseconds: 80),
        ),
      );
      addTearDown(h.state.dispose);
      AppProxy.attach((protocol: 'http', port: 10809));
      addTearDown(() => AppProxy.attach(null));
      h.networks.add([ConnectivityResult.wifi]);
      await h.state.connect();

      await h.state.runDiagnostics().timeout(const Duration(seconds: 5));

      expect(h.state.isDiagnosticsRunning, isFalse,
          reason: 'блокировка снята после завершения');
      expect(h.state.diagnostics!.budgetExceeded, isTrue);

      // Отключение пользователя после проверки выполняется сразу.
      await h.state.disconnect().timeout(const Duration(seconds: 2));
      expect(h.state.state, TunnelState.off);
    });

    test('AppState: отключение во время зависшей пробы не ждёт диагностику',
        () async {
      final gate = Completer<ProbeOutcome>();
      final h = await _harness(
        probe: (uri, {required viaTunnel, timeout = const Duration(seconds: 6)}) =>
            gate.future,
      );
      addTearDown(h.state.dispose);
      AppProxy.attach((protocol: 'http', port: 10809));
      addTearDown(() => AppProxy.attach(null));
      h.networks.add([ConnectivityResult.wifi]);
      await h.state.connect();

      final run = h.state.runDiagnostics();
      await _settle(60);
      expect(h.state.isDiagnosticsRunning, isTrue);

      // Пользователь отключается: действие не заблокировано идущим замером.
      await h.state.disconnect().timeout(const Duration(seconds: 2));
      expect(h.state.state, TunnelState.off);

      gate.complete(const ProbeOutcome(statusCode: 204));
      await run;
      expect(h.state.isDiagnosticsRunning, isFalse);
      final report = h.state.diagnostics!;
      expect(report.cancelled, isTrue);
      expect(report.cancelReason, DiagCancelReason.user);
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
  DiagnosticsBudget? diagnosticsBudget,
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
    diagnosticsBudget: diagnosticsBudget,
    networks: networks.stream,
  );
  return _Harness(state, core, networks);
}

Future<void> _settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));