import 'dart:io';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/autostart.dart';
import 'package:client_vpn/failover.dart';
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/manual_rules.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/routing_presets.dart';
import 'package:client_vpn/rules_screen.dart';
import 'package:client_vpn/settings_screen.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/split_screen.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const linkOne =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

const linkTwo =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000002@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%202';

class _NoCore implements VpnCore {
  @override
  Stream<String> get logs => const Stream<String>.empty();

  @override
  Stream<bool> get statusChanges => const Stream<bool>.empty();

  @override
  bool get isRunning => false;

  @override
  String? get endpointLabel => null;

  @override
  Future<void> validate(VpnConfig config) async {}

  @override
  Future<void> start(VpnConfig config) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> recoverAfterCrash() async {}

  @override
  Future<void> dispose() async {}
}

/// Автозапуск без реестра и без нативного канала.
class _FakeAutostart implements Autostart {
  _FakeAutostart({this.on = false});

  bool on;

  @override
  bool get supported => true;

  @override
  Future<bool> isOn() async => on;

  @override
  Future<void> set(bool value) async => on = value;
}

Future<AppState> makeState({
  Autostart? autostart,
  String languageCode = '',
}) async {
  final prefs = await SharedPreferences.getInstance();
  return AppState(
    await ProfileStore.open(),
    _NoCore(),
    settings: await SettingsStore.open(),
    autostart: autostart ?? _FakeAutostart(),
    presets: PresetStore(prefs),
    ruleStore: RuleStore(prefs),
    configWriter: (config) async => config,
    languageCode: languageCode,
  );
}

Future<void> openSettings(WidgetTester tester, AppState state) async {
  // Экран длинный: без высокого окна список профилей остался бы за пределами
  // отрисованной части ListView.
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      // Экран настроек целиком локализован: без локалей он собрался бы по-английски,
      // а тесты ищут русские строки.
      locale: const Locale('ru'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsScreen(state: state),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('экран настроек', () {
    testWidgets('тема выбирается на месте и остаётся сохранённой', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await openSettings(tester, state);

      expect(find.text('Системная'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.tap(find.text('Тёмная'));
      await tester.pumpAndSettle();

      expect(state.themeChoice, ThemeChoice.dark);
      expect(find.widgetWithIcon(ListTile, Icons.check), findsOneWidget);

      // Перезапуск приложения: значение прочитано из хранилища.
      final reopened = await SettingsStore.open();
      expect(reopened.themeChoice, ThemeChoice.dark);
    });

    testWidgets('автозапуск показывает состояние системы и меняет его', (
      tester,
    ) async {
      final autostart = _FakeAutostart(on: true);
      final state = await makeState(autostart: autostart);
      addTearDown(state.dispose);
      await openSettings(tester, state);

      final toggle = find.byType(SwitchListTile).first;
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(autostart.on, isFalse);
      expect(state.autoStart, isFalse);
    });

    testWidgets('автоподключение включается после первого успешного профиля', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText(linkOne);
      await openSettings(tester, state);

      final autoConnect = find.widgetWithText(
        SwitchListTile,
        'Автоподключение при запуске',
      );
      expect(tester.widget<SwitchListTile>(autoConnect).onChanged, isNull);
      expect(
        find.text('Станет доступно после первого успешного подключения'),
        findsOneWidget,
      );

      // Успешное подключение запоминает профиль — переключатель оживает.
      await state.connect();
      await tester.pumpAndSettle();

      expect(
        find.text('Станет доступно после первого успешного подключения'),
        findsNothing,
      );
      expect(tester.widget<SwitchListTile>(autoConnect).onChanged, isNotNull);
      await tester.tap(autoConnect);
      await tester.pumpAndSettle();
      expect(state.autoConnect, isTrue);
    });

    testWidgets('профили: выбор, переименование и удаление', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText(linkOne);
      await state.addFromText(linkTwo);
      await openSettings(tester, state);

      expect(find.text('Профили (2)'), findsOneWidget);
      // Галочка одна на экране: активный профиль — последний добавленный.
      expect(find.widgetWithIcon(ListTile, Icons.check), findsNWidgets(2));

      await tester.tap(find.text('Узел 1'));
      await tester.pumpAndSettle();
      expect(state.activeProfile?.name, 'Узел 1');

      await tester.tap(find.byTooltip('Действия').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Переименовать'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Домашний');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(
        state.profiles.map((profile) => profile.name),
        contains('Домашний'),
      );

      await tester.tap(find.byTooltip('Действия').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продолжить'));
      await tester.pumpAndSettle();

      expect(state.profiles.length, 1);
      expect(find.text('Профили (1)'), findsOneWidget);
    });
  });

  group('раздельное туннелирование в настройках', () {
    testWidgets('переключатель домашнего региона двигает тот же пресет', (
      tester,
    ) async {
      // Русская локаль устройства: пресет России выбран по умолчанию, поэтому
      // переключатель изначально включён.
      final state = await makeState(languageCode: 'ru');
      addTearDown(state.dispose);
      await openSettings(tester, state);

      final toggle = find.byKey(const ValueKey('home-region-direct'));
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(
        find.text('Зоны: ru, su, рф. Остальное — через подключение.'),
        findsOneWidget,
      );

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(state.routingPreset.key, offPreset.key);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(state.routingPreset.key, 'ru');
      // Выбор пережил «перезапись» состояния: он в хранилище настроек.
      expect(
        PresetStore(await SharedPreferences.getInstance()).load('en').key,
        'ru',
      );
    });

    testWidgets('без домашнего региона маршрут выбирается списком пресетов', (
      tester,
    ) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await openSettings(tester, state);

      // Мёртвый переключатель показывать незачем: вместо него рабочий список
      // пресетов — тот же самый выбор, что и переключатель при известном
      // домашнем регионе.
      expect(find.byKey(const ValueKey('home-region-direct')), findsNothing);
      expect(
        find.text('Домашний регион по языку устройства не определён'),
        findsNothing,
      );
      expect(find.text('Выключено'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('preset-ru')));
      await tester.pumpAndSettle();
      expect(state.routingPreset.key, 'ru');

      // Выбранный ряд неактивен: повтор тот же маршрут оборвал бы соединения.
      expect(
        tester.widget<ListTile>(find.byKey(const ValueKey('preset-ru'))).onTap,
        isNull,
      );
    });

    testWidgets(
      'со своим домашним регионом список не дублирует переключатель',
      (tester) async {
        final state = await makeState(languageCode: 'ru');
        addTearDown(state.dispose);
        await openSettings(tester, state);

        expect(
          find.byKey(const ValueKey('home-region-direct')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('preset-ru')), findsNothing);
        expect(find.byKey(const ValueKey('preset-none')), findsNothing);
      },
    );
  });

  group('переехавшие пункты листа «Дополнительно»', () {
    testWidgets(
      'правила, точка проб, обновления и «о программе» в настройках',
      (tester) async {
        final state = await makeState();
        addTearDown(state.dispose);
        await state.addFromText(linkOne);
        await openSettings(tester, state);

        expect(find.text('Мои правила'), findsOneWidget);
        expect(find.text('Правил пока нет'), findsOneWidget);
        expect(find.text('Обслуживание'), findsOneWidget);
        expect(find.text('Точка проб'), findsOneWidget);
        expect(find.text('Обновление'), findsOneWidget);
        expect(find.text('О программе'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('my-rules')));
        await tester.pumpAndSettle();
        expect(find.byType(RulesScreen), findsOneWidget);
      },
    );

    testWidgets('точка проб правится на экране настроек', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await openSettings(tester, state);

      await tester.tap(find.byKey(const ValueKey('probe-target')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://example.test/ping',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();

      expect(state.probeEndpoint, 'https://example.test/ping');
    });

    testWidgets('плохая точка проб не сохраняется', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await openSettings(tester, state);

      await tester.tap(find.byKey(const ValueKey('probe-target')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'example.test');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();

      expect(state.probeEndpoint, defaultProbeEndpoint);
      expect(
        find.text('Адрес должен начинаться с http:// или https://'),
        findsOneWidget,
      );
    });

    testWidgets('счётчик исключений и переход на экран списка', (tester) async {
      final state = await makeState(languageCode: 'ru');
      addTearDown(state.dispose);
      await state.setSplitHosts(
        direct: ['example.com'],
        tunnel: ['my.office.ru'],
        directTitle: 'Исключения: напрямую',
        tunnelTitle: 'Исключения: в туннель',
      );
      await openSettings(tester, state);

      expect(find.text('напрямую: 1, в туннель: 1'), findsOneWidget);

      await tester.tap(find.text('Адреса-исключения'));
      await tester.pumpAndSettle();

      expect(find.byType(SplitScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('split-host-example.com')),
        findsOneWidget,
      );
    });
  });

  // Ряды выбора относятся к трею, а трей поднимается только на Windows.
  final windowsOnly = !Platform.isWindows;

  group('закрытие окна в настройках', () {
    /// Выбранный ряд — с заполненным кружком.
    Finder chosen(String action) => find.descendant(
      of: find.byKey(ValueKey('close-choice-$action')),
      matching: find.byIcon(Icons.radio_button_checked),
    );

    testWidgets('три варианта, отмечена спрашивать', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await openSettings(tester, state);

      expect(find.text('При закрытии окна'), findsOneWidget);
      expect(find.byKey(const ValueKey('close-choice-ask')), findsOneWidget);
      expect(find.byKey(const ValueKey('close-choice-tray')), findsOneWidget);
      expect(find.byKey(const ValueKey('close-choice-quit')), findsOneWidget);
      expect(chosen('ask'), findsOneWidget);
      expect(chosen('tray'), findsNothing);
    }, skip: windowsOnly);

    testWidgets('выбор сохраняется и после перезапуска', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await openSettings(tester, state);

      await tester.tap(find.text('Сворачивать в трей'));
      await tester.pumpAndSettle();

      expect(state.closeAction, CloseAction.tray);
      expect((await SettingsStore.open()).closeAction, CloseAction.tray);
      expect(chosen('tray'), findsOneWidget);
      expect(chosen('ask'), findsNothing);
    }, skip: windowsOnly);

    testWidgets('запомненный выход показан выбранным', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.setCloseAction(CloseAction.quit);
      await openSettings(tester, state);

      expect(chosen('quit'), findsOneWidget);
    }, skip: windowsOnly);
  });
}
