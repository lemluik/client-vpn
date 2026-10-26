import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/autostart.dart';
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/screens/key_claim/key_claim_screen.dart';
import 'package:client_vpn/services/device_id.dart';
import 'package:client_vpn/services/key_claim_api.dart';
import 'package:client_vpn/services/registration_api.dart' show DeviceData;
import 'package:client_vpn/services/service_config.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Valid placeholder links: example.org from the docs, no live addresses.
const keyOneLink =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org#Первый';

const keyTwoLink =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000002@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org#Второй';

ClaimedKey keyOne({DateTime? expiresAt}) => ClaimedKey(
  link: keyOneLink,
  name: 'Первый',
  entryLabel: 'Вход А',
  expiresAt: expiresAt,
);

ClaimedKey keyTwo({bool trial = true}) => ClaimedKey(
  link: keyTwoLink,
  name: 'Второй',
  entryLabel: 'Вход Б',
  expiresAt: DateTime.utc(2027, 1, 1),
  trial: trial,
  trafficLeftMb: 512,
);

/// A core without a process or network: checks that auto-connect is called.
class _FakeCore implements VpnCore {
  final _logs = StreamController<String>.broadcast();
  final _status = StreamController<CoreStatus>.broadcast();
  bool started = false;

  @override
  Stream<String> get logs => _logs.stream;
  @override
  Stream<CoreStatus> get statusChanges => _status.stream;
  @override
  bool get isRunning => started;
  @override
  String? get endpointLabel => null;
  @override
  Future<void> validate(VpnConfig config) async {}
  @override
  Future<void> start(VpnConfig config) async => started = true;
  @override
  Future<void> stop() async => started = false;
  @override
  Future<void> dispose() async {}
  @override
  Future<void> recoverAfterCrash() async {}
  @override
  Future<void> markTunnelFresh() async {}
  @override
  Future<bool> takePendingConnect() async => false;
}

class _FakeAutostart implements Autostart {
  @override
  bool get supported => false;
  @override
  Future<bool> isOn() async => false;
  @override
  Future<void> set(bool value) async {}
}

/// A fake transport: no network, the list or the error is set by the test.
/// Same approach as `FakeTrayPort`: the screen depends on the interface only.
class _FakeKeyClaimApi implements KeyClaimApi {
  _FakeKeyClaimApi({this.keys = const [], this.error});

  final List<ClaimedKey> keys;
  final Object? error;

  int calls = 0;
  String? lastCode;
  DeviceData? lastDevice;

  @override
  Future<List<ClaimedKey>> claim({
    required String code,
    required DeviceData device,
  }) async {
    calls++;
    lastCode = code;
    lastDevice = device;
    final failure = error;
    if (failure != null) throw failure;
    return keys;
  }
}

class _FakeIdStorage implements IdStorage {
  _FakeIdStorage([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String newValue) async => value = newValue;
}

Future<AppState> makeState({
  ServiceConfig? serviceConfig,
  VpnCore? core,
}) async {
  SharedPreferences.setMockInitialValues({});
  return AppState(
    await ProfileStore.open(),
    core ?? _FakeCore(),
    settings: await SettingsStore.open(),
    autostart: _FakeAutostart(),
    configWriter: (config) async => config,
    serviceConfig: serviceConfig ?? const ServiceConfig(),
  );
}

const claimConfig = ServiceConfig(
  serviceName: 'Пример',
  controlPoint: 'https://control.example.com/',
);

Future<void> pumpClaim(
  WidgetTester tester, {
  required AppState state,
  required KeyClaimApi api,
  DateTime Function()? now,
}) async {
  tester.platformDispatcher.localesTestValue = const [Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: KeyClaimScreen(
        state: state,
        api: api,
        // The real secure storage plugin does not answer in the test environment.
        deviceId: DeviceId(storage: _FakeIdStorage('test-device-id')),
        now: now,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> enterCodeAndSubmit(WidgetTester tester, String code) async {
  await tester.enterText(find.byType(TextField), code);
  await tester.tap(find.text('Показать действующие ключи'));
  await tester.pumpAndSettle();
}

void main() {
  group('контракт: код — единственный секрет', () {
    test('тело запроса содержит только код и данные устройства', () {
      final body = keyClaimRequest(
        'ODN-4417',
        const DeviceData(
          deviceId: 'test-device-id',
          platform: 'windows',
          appVersion: '0.4.2',
        ),
      );

      // No login, phone or user name here, and there must not be: the body is
      // pinned to exactly these four fields (§3).
      expect(body.keys.toSet(), {
        'claim_code',
        'device_id',
        'platform',
        'app_version',
      });
      expect(body['claim_code'], 'ODN-4417');
    });

    testWidgets('фейковый транспорт видит только код и устройство', (
      tester,
    ) async {
      final state = await makeState(serviceConfig: claimConfig);
      addTearDown(state.dispose);
      final api = _FakeKeyClaimApi(keys: [keyOne()]);

      await pumpClaim(tester, state: state, api: api);
      await enterCodeAndSubmit(tester, 'ABC-123');

      expect(api.calls, 1);
      expect(api.lastCode, 'ABC-123');
      expect(api.lastDevice?.deviceId, 'test-device-id');
      expect(api.lastDevice?.platform, isNotEmpty);
      expect(api.lastDevice?.appVersion, isNotEmpty);
    });
  });

  group('сетка раздела 4 на фейковом транспорте', () {
    testWidgets('один действующий ключ — автодобавление и автоподключение', (
      tester,
    ) async {
      final core = _FakeCore();
      final state = await makeState(core: core, serviceConfig: claimConfig);
      addTearDown(state.dispose);
      final api = _FakeKeyClaimApi(keys: [keyOne()]);

      await pumpClaim(tester, state: state, api: api);
      await enterCodeAndSubmit(tester, 'ABC-123');
      await tester.pumpAndSettle();

      expect(state.profiles, hasLength(1));
      expect(state.activeProfile?.name, 'Первый');
      expect(core.started, isTrue);
    });

    testWidgets('несколько ключей — список с полями; истёкшие не показаны', (
      tester,
    ) async {
      final state = await makeState(serviceConfig: claimConfig);
      addTearDown(state.dispose);
      final api = _FakeKeyClaimApi(
        keys: [
          keyOne(),
          keyTwo(),
          keyOne(expiresAt: DateTime.utc(2020, 1, 1)),
        ],
      );

      await pumpClaim(tester, state: state, api: api);
      await enterCodeAndSubmit(tester, 'ABC-123');

      expect(find.text('Действующие ключи этого аккаунта'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('key-claim-choice')));
      await tester.pumpAndSettle();

      expect(
        find.text('Первый · Вход А · без срока · обычный'),
        findsOneWidget,
      );
      expect(
        find.text('Второй · Вход Б · 01.01.2027 · пробный'),
        findsOneWidget,
      );

      await tester.tap(find.text('Второй · Вход Б · 01.01.2027 · пробный'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('key-claim-connect')));
      await tester.pumpAndSettle();

      // The choice creates a profile with the existing mechanism; with several
      // keys connecting stays manual (proposal §8.2, awaiting Р-90).
      expect(state.profiles, hasLength(1));
      expect(state.activeProfile?.name, 'Второй');
    });

    testWidgets('ни одного ключа — заготовленный текст и «повторить»', (
      tester,
    ) async {
      final state = await makeState(serviceConfig: claimConfig);
      addTearDown(state.dispose);
      await state.addFromText(
        keyTwoLink,
      ); // the saved profile must stay
      final api = _FakeKeyClaimApi(keys: const []);

      await pumpClaim(tester, state: state, api: api);
      await enterCodeAndSubmit(tester, 'ABC-123');

      expect(find.text('Для этого аккаунта ключи не выпущены'), findsOneWidget);
      expect(state.profiles, hasLength(1));

      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(api.calls, 1); // "retry" returns to input and does not request by itself
    });

    testWidgets(
      'истёк между списком и подключением — «закончилось» + новый код',
      (tester) async {
        final core = _FakeCore();
        final state = await makeState(core: core, serviceConfig: claimConfig);
        addTearDown(state.dispose);
        final api = _FakeKeyClaimApi(
          keys: [keyOne(expiresAt: DateTime.utc(2026, 10, 22, 12))],
        );

        await pumpClaim(
          tester,
          state: state,
          api: api,
          now: () => DateTime.utc(2026, 10, 22, 13),
        );
        await enterCodeAndSubmit(tester, 'ABC-123');

        expect(
          find.text(
            'Подключение закончилось. Запросите новый код в чате сервиса.',
          ),
          findsOneWidget,
        );
        expect(find.text('Запросить новый код'), findsOneWidget);
        expect(state.profiles, isEmpty);
        expect(core.started, isFalse);
      },
    );

    testWidgets('отзыв (404) — экран «подключение закончилось»', (
      tester,
    ) async {
      final state = await makeState(serviceConfig: claimConfig);
      addTearDown(state.dispose);
      final api = _FakeKeyClaimApi(
        error: KeyClaimException(
          'Подключение закончилось',
          connectionExpired: true,
        ),
      );

      await pumpClaim(tester, state: state, api: api);
      await enterCodeAndSubmit(tester, 'ABC-123');

      expect(
        find.text(
          'Подключение закончилось. Запросите новый код в чате сервиса.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('401 — причина показывается, экран кода остаётся', (
      tester,
    ) async {
      final state = await makeState(serviceConfig: claimConfig);
      addTearDown(state.dispose);
      final api = _FakeKeyClaimApi(
        error: KeyClaimException(
          'Код не принят — запросите новый в чате сервиса',
        ),
      );

      await pumpClaim(tester, state: state, api: api);
      await enterCodeAndSubmit(tester, 'ABC-123');

      expect(
        find.text(
          'Не удалось получить ключи: Код не принят — запросите новый в чате сервиса',
        ),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('без точки контроля (открытый клиент) — «Сервис не настроен»', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: KeyClaimScreen(
            state: state,
            deviceId: DeviceId(storage: _FakeIdStorage('test-device-id')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await enterCodeAndSubmit(tester, 'ABC-123');

      expect(
        find.text('Не удалось получить ключи: Сервис не настроен'),
        findsOneWidget,
      );
    });
  });
}
