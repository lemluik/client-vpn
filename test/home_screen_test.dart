import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/chat_service.dart';
import 'package:client_vpn/chat_store.dart';
import 'package:client_vpn/home_screen.dart';
import 'package:client_vpn/main.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const linkOne = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

const linkTwo = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:8443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%202';

/// Ядро без процесса и без сети: состояние переключается вручную.
class FakeCore implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<bool> _status = StreamController<bool>.broadcast();

  Object? validateError;
  int startCalls = 0;
  VpnConfig? lastConfig;
  bool _running = false;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  Stream<bool> get statusChanges => _status.stream;

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
    _status.add(true);
  }

  @override
  Future<void> stop() async {
    _running = false;
    _status.add(false);
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<void> recoverAfterCrash() async {}

  void emitLog(String line) => _logs.add(line);

  /// Обрыв со стороны ядра: приложение остановки не просило.
  void dropConnection() {
    _running = false;
    _status.add(false);
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

Future<AppState> makeState({FakeCore? core}) async {
  SharedPreferences.setMockInitialValues({});
  return AppState(
    await ProfileStore.open(),
    core ?? FakeCore(),
    // Запись служебного конфига проверена отдельно в temp_config_test.
    configWriter: (config) async => config,
  );
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

    testWidgets('английская локаль устройства даёт английский интерфейс',
        (tester) async {
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

    testWidgets('кнопка поддержки видна и без добавленного подключения',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(
        await ProfileStore.open(),
        FakeCore(),
        configWriter: (config) async => config,
        chat: ChatService(ChatStore(
          await SharedPreferences.getInstance(),
          _NullVault(),
        )),
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

    testWidgets('плюс в шапке добавляет подключение к существующим',
        (tester) async {
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
          final decoration =
              widget is AnimatedContainer ? widget.decoration : null;
          return decoration is BoxDecoration &&
              decoration.shape == BoxShape.circle;
        }),
        findsOneWidget,
      );
      expect(tester.getCenter(orb).dx, 400);

      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();

      expect(find.text('Защищено'), findsOneWidget);
      expect(core.startCalls, 1);
      expect(core.lastConfig?.json, contains('cvpn-proxy'));

      await tester.tap(find.text('Отключить'));
      await tester.pumpAndSettle();

      expect(find.text('Отключено'), findsOneWidget);
      expect(core.startCalls, 1);
    });

    testWidgets('отказ ядра показывает причину и действие', (tester) async {
      final core = FakeCore()
        ..validateError =
            Exception('Валидация не пройдена (код 1): битый конфиг');
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
    });

    testWidgets('обрыв со стороны ядра — это сбой, а не отключение',
        (tester) async {
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
      expect(find.text('Подключитесь снова: профиль сохранён'), findsOneWidget);
    });

    testWidgets('журнал живёт на отдельном экране и маскируется',
        (tester) async {
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

    testWidgets('смена страны на поднятом туннеле спрашивает разрешение',
        (tester) async {
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

    testWidgets('Windows не показывает значок флага, название остаётся',
        (tester) async {
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

    testWidgets('акцентный цвет системы перекрашивает интерфейс',
        (tester) async {
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

    testWidgets('переключение туннеля подтверждается осязанием',
        (tester) async {
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
}
