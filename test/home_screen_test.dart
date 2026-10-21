import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/autostart.dart';
import 'package:client_vpn/chat_service.dart';
import 'package:client_vpn/chat_store.dart';
import 'package:client_vpn/failover.dart';
import 'package:client_vpn/home_screen.dart';
import 'package:client_vpn/main.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/services/service_config.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const linkOne =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

const linkTwo =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:8443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%202';

/// Ядро без процесса и без сети: состояние переключается вручную.
class FakeCore implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<CoreStatus> _status =
      StreamController<CoreStatus>.broadcast();

  Object? validateError;
  int startCalls = 0;
  VpnConfig? lastConfig;
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
  String? get endpointLabel => _running ? 'http 127.0.0.1:10808' : null;

  @override
  Future<void> validate(VpnConfig config) async {
    final error = validateError;
    if (error != null) throw error;
  }

  @override
  Future<void> start(VpnConfig config) async {
    startCalls++;
    lastConfig = config;
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

  void emitLog(String line) => _logs.add(line);

  /// Обрыв со стороны ядра: приложение остановки не просило.
  void dropConnection() {
    _running = false;
    _status.add(const CoreStatus(false));
  }
}

/// Хранилище токенов без содержимого: тест проверяет путь до формы входа,
/// а не шифрование — оно разобрано в chat_store_test.
class _NullVault implements TokenVault {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> erase(String key) async {}
}

Future<AppState> makeState({
  FakeCore? core,
  Autostart? autostart,
  ServiceConfig? serviceConfig,
}) async {
  SharedPreferences.setMockInitialValues({});
  return AppState(
    await ProfileStore.open(),
    core ?? FakeCore(),
    settings: await SettingsStore.open(),
    autostart: autostart ?? FakeAutostart(),
    // Запись служебного конфига проверена отдельно в temp_config_test.
    configWriter: (config) async => config,
    serviceConfig: serviceConfig ?? const ServiceConfig(),
  );
}

/// Автозапуск без реестра: экран настроек проверяет только чтение и запись флага.
class FakeAutostart implements Autostart {
  bool on = false;

  @override
  bool get supported => true;

  @override
  Future<bool> isOn() async => on;

  @override
  Future<void> set(bool value) async => on = value;
}

/// Тесты ищут русские строки, поэтому язык задаём явно: локаль тестовой среды
/// английская, и без этого интерфейс собрался бы по-английски.
Future<void> pumpApp(WidgetTester tester, AppState state) async {
  // Язык выбирается по списку локалей устройства, поэтому задаём именно его.
  tester.platformDispatcher.localesTestValue = const [Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  await tester.pumpWidget(ClientVpnApp(state: state));
}

void main() {
  group('главный экран', () {
    testWidgets('первый запуск: одно объяснение и одна кнопка', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      expect(find.text('Быстрый доступ в интернет'), findsOneWidget);
      expect(find.text('Добавить подключение'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byTooltip('Добавить подключение'), findsOneWidget);
      expect(find.text('Отключено'), findsOneWidget);
    });

    testWidgets('английская локаль устройства даёт английский интерфейс', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      tester.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      await tester.pumpWidget(ClientVpnApp(state: state));
      await tester.pumpAndSettle();

      expect(find.text('Quick access to the internet'), findsOneWidget);
      expect(find.text('Add connection'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('шестерёнка слева открывает настройки', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText(linkOne);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      // Кнопка в leading: слева, в том же стиле, что журнал и чат.
      final gear = find.byTooltip('Настройки');
      expect(gear, findsOneWidget);
      expect(tester.getCenter(gear).dx, lessThan(60));

      // Редкие действия — слева, частые справа, по две кнопки с каждой стороны.
      expect(tester.getCenter(find.byTooltip('Журнал')).dx, lessThan(110));
      expect(
        tester.getCenter(find.byTooltip('Добавить подключение')).dx,
        greaterThan(400),
      );
      expect(
        tester.getCenter(find.byTooltip('Поддержка')).dx,
        greaterThan(400),
      );

      await tester.tap(gear);
      await tester.pumpAndSettle();

      expect(find.text('Оформление'), findsOneWidget);
      expect(find.text('Автоподключение при запуске'), findsOneWidget);

      // Второй настроечной кнопки на первом экране нет: её пункты переехали
      // под шестерёнку, и один и тот же выбор в двух местах не показывается.
      expect(find.byTooltip('Дополнительно'), findsNothing);
      expect(find.byIcon(Icons.tune), findsNothing);
    });

    testWidgets(
      'автоподключение при запуске поднимает последний успешный профиль',
      (tester) async {
        final first = await makeState();
        addTearDown(first.dispose);
        await first.addFromText(linkOne);
        await first.setAutoConnect(true);
        await first.connect();
        expect(first.isConnected, isTrue);

        // Перезапуск приложения: то же хранилище, новое ядро.
        final core = FakeCore();
        final restarted = AppState(
          await ProfileStore.open(),
          core,
          settings: await SettingsStore.open(),
          configWriter: (config) async => config,
        );
        addTearDown(restarted.dispose);

        await restarted.autoConnectOnLaunch();

        expect(restarted.autoConnect, isTrue);
        expect(core.startCalls, 1);
        expect(restarted.activeProfile?.id, first.settings.lastProfileId);
      },
    );

    testWidgets('кнопка поддержки видна и без добавленного подключения', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(
        await ProfileStore.open(),
        FakeCore(),
        settings: await SettingsStore.open(),
        configWriter: (config) async => config,
        chat: ChatService(
          ChatStore(await SharedPreferences.getInstance(), _NullVault()),
        ),
      );
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Поддержка'));
      await tester.pumpAndSettle();

      expect(find.text('Чат поддержки'), findsOneWidget);
      expect(find.byKey(const ValueKey('homeserver')), findsOneWidget);
    });
    testWidgets('ссылка из буфера поднимает профиль без файла', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Добавить подключение'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ссылка или подписка'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), linkOne);
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();

      expect(find.text('Узел 1'), findsOneWidget);
      expect(find.text('Один профиль'), findsOneWidget);
      expect(state.profiles, hasLength(1));
      expect(state.profiles.single.kind, ProfileKind.links);
    });

    testWidgets('плюс в шапке добавляет подключение к существующим', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText(linkOne);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Добавить подключение'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ссылка или подписка'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), linkTwo);
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();

      expect(state.profiles, hasLength(2));
      expect(find.text('Узел 2'), findsOneWidget);
    });

    testWidgets('подключение и отключение одной кнопкой', (tester) async {
      final core = FakeCore();
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      await state.addFromText('$linkOne\n$linkTwo');

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      expect(find.text('2 профилей'), findsOneWidget);

      // Кнопка — круг по центру экрана, плавающей кнопки больше нет.
      final orb = find.byIcon(Icons.power_settings_new);
      expect(orb, findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(
        find.byWidgetPredicate((widget) {
          final decoration = widget is AnimatedContainer
              ? widget.decoration
              : null;
          return decoration is BoxDecoration &&
              decoration.shape == BoxShape.circle;
        }),
        findsOneWidget,
      );
      expect(tester.getCenter(orb).dx, 400);
      // По вертикали — середина свободной области, а не низ экрана.
      expect(tester.getCenter(orb).dy, inInclusiveRange(200, 400));
      // Строка статуса прижата к нижнему краю окна, а не висит под диском.
      expect(tester.getRect(find.text('Отключено')).bottom, greaterThan(520));

      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(find.text('Защищено'), findsOneWidget);
      // Подключённый диск не меняет значок: питание то же, свечение другое.
      expect(find.byIcon(Icons.power_settings_new), findsOneWidget);
      expect(core.startCalls, 1);
      expect(core.lastConfig?.json, contains('cvpn-proxy'));

      await tester.tap(find.text('Отключить'));
      await tester.pumpAndSettle();

      expect(find.text('Отключено'), findsOneWidget);
      expect(core.startCalls, 1);
    });

    testWidgets('отказ ядра показывает причину и действие', (tester) async {
      final core = FakeCore()
        ..validateError = Exception(
          'Валидация не пройдена (код 1): битый конфиг',
        );
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      await state.addFromText(linkOne);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(find.text('Сбой'), findsOneWidget);
      expect(
        find.text('Валидация не пройдена (код 1): битый конфиг'),
        findsOneWidget,
      );
      expect(
        find.text('Подключитесь снова или выберите другой профиль'),
        findsOneWidget,
      );
      expect(find.text('Подключить снова'), findsOneWidget);
      // Сбой ставит в очередь пробу и паузу подписки; фазовые часы теста
      // не прощают незакрытых таймеров, поэтому снимаем их отключением.
      await state.disconnect();
    });

    testWidgets('обрыв со стороны ядра — это сбой, а не отключение', (
      tester,
    ) async {
      final core = FakeCore();
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      await state.addFromText(linkOne);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      core.dropConnection();
      await tester.pumpAndSettle();

      expect(find.text('Сбой'), findsOneWidget);
      expect(find.text('Соединение прервано'), findsOneWidget);
      expect(
        find.text('Подключитесь снова или обновите подписку'),
        findsOneWidget,
      );
      await state.disconnect();
    });

    testWidgets('журнал живёт на отдельном экране и маскируется', (
      tester,
    ) async {
      final core = FakeCore();
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      await state.addFromText(linkOne);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      core.emitLog(
        'узел 203.0.113.7 ключ SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234',
      );
      await tester.pumpAndSettle();

      expect(find.text('Журнал'), findsNothing);

      await tester.tap(find.byTooltip('Журнал'));
      await tester.pumpAndSettle();

      expect(find.text('Журнал'), findsOneWidget);
      expect(find.text('узел [адрес] ключ [ключ]'), findsOneWidget);
      expect(state.exportLog(), contains('[адрес]'));
      expect(state.exportLog(), isNot(contains('203.0.113.7')));
    });
  });

  group('регион выхода', () {
    /// Ссылка узла: порт различает профили, имя задаёт регион.
    String node(int port, String remark) =>
        'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:$port'
        '?encryption=none&security=reality'
        '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
        '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
        '&flow=xtls-rprx-vision#${Uri.encodeComponent(remark)}';

    final twoRegionLinks = [
      node(443, '🇩🇪 Germany 1'),
      node(8443, '🇩🇪 Germany 2'),
      node(2053, '🇫🇮 Finland 1'),
    ].join('\n');

    const germanyLabel = '🇩🇪 Germany';
    const finlandLabel = '🇫🇮 Finland';

    testWidgets('выбор страны из списка меняет путь туннеля', (tester) async {
      final core = FakeCore();
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      // Реальный размер окна клиента: строка выбора страны обязана помещаться.
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await state.addFromText(twoRegionLinks);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      expect(find.text('Страна выхода'), findsOneWidget);
      expect(find.text(germanyLabel), findsOneWidget);

      await tester.tap(find.text(germanyLabel));
      await tester.pumpAndSettle();
      expect(find.text('Профилей: 2'), findsOneWidget);
      expect(find.text('Профилей: 1'), findsOneWidget);

      await tester.tap(find.text(finlandLabel));
      await tester.pumpAndSettle();

      expect(state.activeRegion?.key, 'finland');
      expect(find.text(finlandLabel), findsOneWidget);

      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(core.startCalls, 1);
      expect(core.lastConfig?.json, contains('"port":2053'));
      expect(core.lastConfig?.json, isNot(contains('"port":443')));
    });

    testWidgets('смена страны на поднятом туннеле спрашивает разрешение', (
      tester,
    ) async {
      final core = FakeCore();
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      await state.addFromText(twoRegionLinks);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(germanyLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(finlandLabel));
      await tester.pumpAndSettle();

      expect(find.text('Сменить страну выхода?'), findsOneWidget);
      expect(core.startCalls, 1);

      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();

      expect(state.activeRegion?.key, 'finland');
      expect(core.startCalls, 2);
      expect(find.text('Отключить'), findsOneWidget);
    });

    testWidgets('подписка одного региона не показывает выбор', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText('$linkOne\n$linkTwo');

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      expect(find.text('Страна выхода'), findsNothing);
    });

    testWidgets('Windows не показывает значок флага, название остаётся', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText(twoRegionLinks);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('🇩🇪 Germany'), findsNothing);
      // Значение foundation-переменной обязано вернуться в null до конца теста.
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('палитра под цвета системы и отклик кнопки', () {
    const dynamicChannel = MethodChannel('io.material.plugins/dynamic_color');

    /// Отвечаем системе за палитру: ядро палитры не отдаём, как на десктопе,
    /// а акцентный цвет — тот, что задал тест.
    void mockSystemAccent(WidgetTester tester, int? argb) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(dynamicChannel, (call) async {
        if (call.method == 'getAccentColor') return argb;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(dynamicChannel, null),
      );
    }

    ColorScheme schemeOf(WidgetTester tester) =>
        Theme.of(tester.element(find.byType(HomeScreen))).colorScheme;

    testWidgets('система без палитры оставляет посевной синий', (tester) async {
      mockSystemAccent(tester, null);
      final state = await makeState();
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      expect(
        schemeOf(tester).primary,
        ColorScheme.fromSeed(seedColor: Colors.blue).primary,
      );
    });

    testWidgets('акцентный цвет системы перекрашивает интерфейс', (
      tester,
    ) async {
      mockSystemAccent(tester, 0xFF6750A4);
      final state = await makeState();
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      expect(
        schemeOf(tester).primary,
        ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)).primary,
      );
      expect(
        schemeOf(tester).primary,
        isNot(ColorScheme.fromSeed(seedColor: Colors.blue).primary),
      );
    });

    testWidgets('переключение туннеля подтверждается осязанием', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText(linkOne);

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            calls.add(call);
            return null;
          });

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.power_settings_new));
      await tester.pumpAndSettle();

      final taps = calls
          .where((call) => call.method == 'HapticFeedback.vibrate')
          .toList();
      expect(taps, hasLength(1));
      expect(taps.single.arguments, 'HapticFeedbackType.mediumImpact');
    });
  });

  group('отказоустойчивость: балансировщик региона и точка проб', () {
    Future<AppState> stateWithProbeStore(FakeCore core) async {
      SharedPreferences.setMockInitialValues({});
      return AppState(
        await ProfileStore.open(),
        core,
        settings: await SettingsStore.open(),
        configWriter: (config) async => config,
        probes: ProbeStore(await SharedPreferences.getInstance()),
      );
    }

    testWidgets('настроенная точка проб уходит в конфиг ядра', (tester) async {
      final core = FakeCore();
      final state = await stateWithProbeStore(core);
      addTearDown(state.dispose);
      await state.addFromText('$linkOne\n$linkTwo');

      await pumpApp(tester, state);
      await tester.pumpAndSettle();

      // Значение точки проб правится на экране настроек под шестерёнкой, а
      // здесь проверяется, что оно доходит до конфига ядра.
      await state.setProbeEndpoint('https://example.test/ping');
      expect(state.probeEndpoint, 'https://example.test/ping');

      await state.connect();
      final json = core.lastConfig!.json;
      expect(json, contains('"probeURL":"https://example.test/ping"'));
      // Без списка субъектов наблюдатель не делает ни одной пробы и стратегия
      // навсегда остаётся на первом узле (замер 21.10.2026, test/stand).
      expect(json, contains('"subjectSelector":["cvpn-proxy","cvpn-proxy-2"]'));
      // Два узла одного региона — правило ведёт на балансировщик (МК-6).
      expect(json, contains('"balancerTag":"cvpn-lb"'));
      expect(json, contains('"strategy":{"type":"leastPing"'));
      expect(json, contains('"tolerance":$regionToleranceMs'));
    });
  });

  group('подключение пробного ключа в меню «+»', () {
    const trialConfig = ServiceConfig(
      serviceName: 'Example',
      controlPoint: 'https://control.example.com/',
      trialEnabled: true,
    );

    testWidgets('пункт первый, с молнией и именем из конфига', (tester) async {
      final state = await makeState(serviceConfig: trialConfig);
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Добавить подключение'));
      await tester.pumpAndSettle();

      final trial = find.text('Подключить Example');
      expect(trial, findsOneWidget);
      expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
      // Пробный ключ — первый пункт, выше импорта ссылки.
      expect(
        tester.getTopLeft(trial).dy,
        lessThan(tester.getTopLeft(find.text('Ссылка или подписка')).dy),
      );
    });

    testWidgets('имя берётся из конфига, а не зашито в код', (tester) async {
      final state = await makeState(serviceConfig: trialConfig);
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Добавить подключение'));
      await tester.pumpAndSettle();

      expect(find.text('Подключить Example'), findsOneWidget);
      expect(find.text('Подключить сервис'), findsNothing);
    });

    testWidgets('без бренда в конфиге пункт читается «Подключить сервис»', (
      tester,
    ) async {
      final state = await makeState(
        serviceConfig: const ServiceConfig(trialEnabled: true),
      );
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Добавить подключение'));
      await tester.pumpAndSettle();

      expect(find.text('Подключить сервис'), findsOneWidget);
    });

    testWidgets(
      'открытый клиент без конфига: пункт виден с нейтральной меткой',
      (tester) async {
        final state = await makeState();
        addTearDown(state.dispose);

        await pumpApp(tester, state);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Добавить подключение'));
        await tester.pumpAndSettle();

        // Кнопка видна всегда (решение владельца 20.10), без конфига — fallback.
        expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
        expect(find.text('Подключить сервис'), findsOneWidget);
        // Универсальные пункты на месте.
        expect(find.text('Ссылка или подписка'), findsOneWidget);
      },
    );

    testWidgets('тап по пункту открывает экран подключения', (tester) async {
      final state = await makeState(serviceConfig: trialConfig);
      addTearDown(state.dispose);

      await pumpApp(tester, state);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Добавить подключение'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подключить Example'));
      await tester.pumpAndSettle();

      expect(
        find.text('Согласен с условиями программы тестирования'),
        findsOneWidget,
      );
      expect(find.text('Подключить'), findsOneWidget);
    });
  });
}
