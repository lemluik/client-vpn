import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/autostart.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/settings_screen.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const linkOne = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

const linkTwo = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000002@example.org:443'
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

Future<AppState> makeState({Autostart? autostart}) async {
  return AppState(
    await ProfileStore.open(),
    _NoCore(),
    settings: await SettingsStore.open(),
    autostart: autostart ?? _FakeAutostart(),
    configWriter: (config) async => config,
  );
}

Future<void> openSettings(WidgetTester tester, AppState state) async {
  // Экран длинный: без высокого окна список профилей остался бы за пределами
  // отрисованной части ListView.
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp(
    home: SettingsScreen(state: state),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('экран настроек', () {
    testWidgets('тема выбирается на месте и остаётся сохранённой',
        (tester) async {
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

    testWidgets('автозапуск показывает состояние системы и меняет его',
        (tester) async {
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

    testWidgets('автоподключение включается после первого успешного профиля',
        (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText(linkOne);
      await openSettings(tester, state);

      final autoConnect = find.widgetWithText(SwitchListTile, 'Автоподключение при запуске');
      expect(tester.widget<SwitchListTile>(autoConnect).onChanged, isNull);
      expect(find.text('Станет доступно после первого успешного подключения'),
          findsOneWidget);

      // Успешное подключение запоминает профиль — переключатель оживает.
      await state.connect();
      await tester.pumpAndSettle();

      expect(find.text('Станет доступно после первого успешного подключения'),
          findsNothing);
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
      expect(state.profiles.map((profile) => profile.name), contains('Домашний'));

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
}
