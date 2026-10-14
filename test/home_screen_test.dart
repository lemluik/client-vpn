import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/main.dart';
import 'package:client_vpn/profile_store.dart';
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

Future<AppState> makeState({FakeCore? core}) async {
  SharedPreferences.setMockInitialValues({});
  return AppState(
    await ProfileStore.open(),
    core ?? FakeCore(),
    // Запись служебного конфига проверена отдельно в temp_config_test.
    configWriter: (config) async => config,
  );
}

void main() {
  group('главный экран', () {
    testWidgets('первый запуск: одно объяснение и одна кнопка', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);

      await tester.pumpWidget(ClientVpnApp(state: state));
      await tester.pumpAndSettle();

      expect(find.text('Быстрый доступ в интернет'), findsOneWidget);
      expect(find.text('Добавить подключение'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Отключено'), findsOneWidget);
    });

    testWidgets('ссылка из буфера поднимает профиль без файла', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);

      await tester.pumpWidget(ClientVpnApp(state: state));
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

    testWidgets('подключение и отключение одной кнопкой', (tester) async {
      final core = FakeCore();
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      await state.addFromText('$linkOne\n$linkTwo');

      await tester.pumpWidget(ClientVpnApp(state: state));
      await tester.pumpAndSettle();

      expect(find.text('2 профилей'), findsOneWidget);
      await tester.tap(find.text('ПОДКЛЮЧИТЬ'));
      await tester.pumpAndSettle();

      expect(find.text('Защищено'), findsOneWidget);
      expect(core.startCalls, 1);
      expect(core.lastConfig?.json, contains('cvpn-proxy'));

      await tester.tap(find.text('ОТКЛЮЧИТЬ'));
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

      await tester.pumpWidget(ClientVpnApp(state: state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ПОДКЛЮЧИТЬ'));
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
      expect(find.text('ПОДКЛЮЧИТЬ СНОВА'), findsOneWidget);
    });

    testWidgets('обрыв со стороны ядра — это сбой, а не отключение',
        (tester) async {
      final core = FakeCore();
      final state = await makeState(core: core);
      addTearDown(state.dispose);
      await state.addFromText(linkOne);

      await tester.pumpWidget(ClientVpnApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ПОДКЛЮЧИТЬ'));
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

      await tester.pumpWidget(ClientVpnApp(state: state));
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

      await tester.pumpWidget(ClientVpnApp(state: state));
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

      await tester.tap(find.text('ПОДКЛЮЧИТЬ'));
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

      await tester.pumpWidget(ClientVpnApp(state: state));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ПОДКЛЮЧИТЬ'));
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
      expect(find.text('ОТКЛЮЧИТЬ'), findsOneWidget);
    });

    testWidgets('подписка одного региона не показывает выбор', (tester) async {
      final state = await makeState();
      addTearDown(state.dispose);
      await state.addFromText('$linkOne\n$linkTwo');

      await tester.pumpWidget(ClientVpnApp(state: state));
      await tester.pumpAndSettle();

      expect(find.text('Страна выхода'), findsNothing);
    });
  });
}
