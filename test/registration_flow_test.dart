import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/autostart.dart';
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/screens/expired_key_screen.dart';
import 'package:client_vpn/screens/registration/registration_screen.dart';
import 'package:client_vpn/services/device_id.dart';
import 'package:client_vpn/services/registration_api.dart';
import 'package:client_vpn/services/service_config.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Действительная ссылка Reality — из неё клиент собирает профиль.
const validKey =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#Trial';

/// Ядро без процесса и сети: нужно только чтобы AppState собрался.
class _FakeCore implements VpnCore {
  final _logs = StreamController<String>.broadcast();
  final _status = StreamController<bool>.broadcast();
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
  Future<void> start(VpnConfig config) async => _running = true;
  @override
  Future<void> stop() async => _running = false;
  @override
  Future<void> dispose() async {}
  @override
  Future<void> recoverAfterCrash() async {}
}

class _FakeAutostart implements Autostart {
  @override
  bool get supported => false;
  @override
  Future<bool> isOn() async => false;
  @override
  Future<void> set(bool value) async {}
}

/// Заглушка API: сеть не поднимается, ответ или ошибка заданы тестом.
class _FakeRegistrationApi implements RegistrationApi {
  _FakeRegistrationApi({this.error});

  final Object? error;
  String? lastLogin;
  DeviceData? lastDevice;
  int calls = 0;

  @override
  Future<RegistrationResult> register({
    required String telegramLogin,
    required DeviceData device,
  }) async {
    calls++;
    lastLogin = telegramLogin;
    lastDevice = device;
    final failure = error;
    if (failure != null) throw failure;
    return const RegistrationResult(key: validKey, serviceName: 'Example');
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

Future<AppState> makeState({ServiceConfig? serviceConfig}) async {
  SharedPreferences.setMockInitialValues({});
  return AppState(
    await ProfileStore.open(),
    _FakeCore(),
    settings: await SettingsStore.open(),
    autostart: _FakeAutostart(),
    configWriter: (config) async => config,
    serviceConfig: serviceConfig ?? const ServiceConfig(),
  );
}

const trialConfig = ServiceConfig(
  serviceName: 'Example',
  controlPoint: 'https://control.example.com/',
  trialEnabled: true,
);

Future<void> pumpRegistration(
  WidgetTester tester, {
  required AppState state,
  RegistrationApi? api,
  DeviceId? deviceId,
}) async {
  // По умолчанию идентификатор берём из памяти: настоящий плагин защищённого
  // хранилища в тестовой среде не отвечает, и запрос бы завис.
  final device =
      deviceId ?? DeviceId(storage: _FakeIdStorage('test-device-id'));
  tester.platformDispatcher.localesTestValue = const [Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RegistrationScreen(
                    state: state,
                    api: api,
                    deviceId: device,
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('normalizeTelegramLogin', () {
    test('убирает пробелы и ведущий «@»', () {
      expect(normalizeTelegramLogin('  @test_user '), 'test_user');
      expect(normalizeTelegramLogin('test_user'), 'test_user');
    });

    test('принимает от 5 до 32 символов', () {
      expect(normalizeTelegramLogin('abcde'), 'abcde');
      expect(normalizeTelegramLogin('a' * 32), 'a' * 32);
    });

    test('отклоняет короткое, длинное и недопустимые символы', () {
      expect(normalizeTelegramLogin('abcd'), isNull);
      expect(normalizeTelegramLogin('a' * 33), isNull);
      expect(normalizeTelegramLogin('user name'), isNull);
      expect(normalizeTelegramLogin('user-name'), isNull);
      expect(normalizeTelegramLogin('юзер12'), isNull);
      expect(normalizeTelegramLogin(''), isNull);
      expect(normalizeTelegramLogin('@'), isNull);
    });
  });

  group('экран подключения', () {
    testWidgets('без согласия запрос не уходит', (tester) async {
      final state = await makeState(serviceConfig: trialConfig);
      addTearDown(state.dispose);
      final api = _FakeRegistrationApi();

      await pumpRegistration(tester, state: state, api: api);
      await tester.enterText(find.byType(TextField), '@testuser');
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(api.calls, 0);
      expect(
        find.text('Необходимо согласиться с условиями программы'),
        findsOneWidget,
      );
    });

    testWidgets('неверный логин — запрос не уходит', (tester) async {
      final state = await makeState(serviceConfig: trialConfig);
      addTearDown(state.dispose);
      final api = _FakeRegistrationApi();

      await pumpRegistration(tester, state: state, api: api);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(api.calls, 0);
      expect(
        find.text('Введите Telegram login: @username, от 5 до 32 символов'),
        findsOneWidget,
      );
    });

    testWidgets('успех добавляет ключ и показывает подтверждение', (
      tester,
    ) async {
      final state = await makeState(serviceConfig: trialConfig);
      addTearDown(state.dispose);
      final api = _FakeRegistrationApi();
      final device = DeviceId(storage: _FakeIdStorage('fixed-device-id'));

      await pumpRegistration(tester, state: state, api: api, deviceId: device);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'testuser');
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(api.calls, 1);
      // Логин уходит с «@» впереди, идентификатор — из хранилища устройства.
      expect(api.lastLogin, '@testuser');
      expect(api.lastDevice?.deviceId, 'fixed-device-id');
      expect(api.lastDevice?.appVersion, isNotEmpty);
      expect(state.profiles, hasLength(1));
      expect(find.text('Подключено! Ключ добавлен.'), findsOneWidget);
    });

    testWidgets('ошибка сервиса показывается пользователю', (tester) async {
      final state = await makeState(serviceConfig: trialConfig);
      addTearDown(state.dispose);
      final api = _FakeRegistrationApi(
        error: RegistrationException('Сервис недоступен'),
      );

      await pumpRegistration(tester, state: state, api: api);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '@testuser');
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(state.profiles, isEmpty);
      expect(
        find.text('Не удалось подключиться: Сервис недоступен'),
        findsOneWidget,
      );
    });

    testWidgets('без точки контроля (открытый клиент) — «Сервис не настроен»', (
      tester,
    ) async {
      // trialEnabled, но controlPoint не задан: запрос уходит в заглушку? Нет —
      // экран не получает api и сообщает, что сервис не настроен.
      final state = await makeState(
        serviceConfig: const ServiceConfig(trialEnabled: true),
      );
      addTearDown(state.dispose);

      await pumpRegistration(tester, state: state);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '@testuser');
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(
        find.text('Не удалось подключиться: Сервис не настроен'),
        findsOneWidget,
      );
    });
  });

  group('экран «Ключ истёк»', () {
    testWidgets('показывает причину, поддержку и срок программы', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      tester.platformDispatcher.localesTestValue = const [Locale('ru')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      var supportOpened = false;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ExpiredKeyScreen(
            state: state,
            onOpenSupport: () => supportOpened = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ключ истёк'), findsOneWidget);
      expect(find.text('Ваш временный ключ закончился.'), findsOneWidget);
      expect(
        find.text('Для продления обратитесь в службу поддержки'),
        findsOneWidget,
      );
      expect(
        find.text('Программа тестирования действительна до 31.10.2026'),
        findsOneWidget,
      );

      await tester.tap(find.text('Открыть поддержку'));
      expect(supportOpened, isTrue);
    });
  });
}
