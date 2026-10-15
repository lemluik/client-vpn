import 'dart:async';
import 'dart:convert';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/manual_rules.dart';
import 'package:client_vpn/per_app_rules.dart';
import 'package:client_vpn/profile_config.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/routing_presets.dart';
import 'package:client_vpn/rules_screen.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const link = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4#Один';

ManualRule rule({
  String id = 'r1',
  String title = 'Банк',
  String outbound = directTag,
  bool enabled = true,
  Map<RuleField, List<String>> conditions = const {
    RuleField.domain: ['sberbank.ru'],
  },
}) => ManualRule(
  id: id,
  title: title,
  outbound: outbound,
  conditions: conditions,
  enabled: enabled,
);

/// Ядро, которое помнит конфиг подключения и отдаёт его тесту.
class CapturingCore implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<CoreStatus> _status = StreamController<CoreStatus>.broadcast();

  String? lastConfig;

  @override
  Stream<String> get logs => _logs.stream;

  @override
  Stream<CoreStatus> get statusChanges => _status.stream;

  @override
  Future<void> markTunnelFresh() async {}

  @override
  Future<bool> takePendingConnect() async => false;

  @override
  bool get isRunning => true;

  @override
  String? get endpointLabel => null;

  @override
  Future<void> validate(VpnConfig config) async {}

  @override
  Future<void> start(VpnConfig config) async => lastConfig = config.json;

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> recoverAfterCrash() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('правило как данные ядра', () {
    test('списочные поля идут списком, одиночные — строкой через запятую', () {
      final xray = rule(
        conditions: const {
          RuleField.domain: ['sberbank.ru', 'geosite:category-bank-ru'],
          RuleField.port: ['443', '8443'],
          RuleField.network: ['tcp', 'udp'],
        },
      ).toXrayRule();

      expect(xray['type'], 'field');
      expect(xray['domain'], ['sberbank.ru', 'geosite:category-bank-ru']);
      // Ядро читает port одной строкой: список оно отвергает.
      expect(xray['port'], '443,8443');
      expect(xray['network'], 'tcp,udp');
      expect(xray['outboundTag'], directTag);
    });

    test('направление «через подключение» — тег прокси', () {
      expect(
        rule(outbound: proxyTag).toXrayRule()['outboundTag'],
        proxyTag,
      );
    });

    test('выключенное и невалидное правило в конфиг не идёт', () {
      final rules = ManualRule.xrayRules([
        rule(id: 'a'),
        rule(id: 'b', enabled: false),
        rule(id: 'c', conditions: const {}),
      ]);

      expect(rules, hasLength(1));
      expect(rules.first['domain'], ['sberbank.ru']);
    });

    test('девять условий — ровно те, что принимает ядро', () {
      expect(
        RuleField.values.map((field) => field.key).toList(),
        [
          'domain',
          'ip',
          'port',
          'sourcePort',
          'network',
          'protocol',
          'source',
          'inboundTag',
          'user',
        ],
      );
    });
  });

  group('проверка правила', () {
    test('без условия ядро правило не принимает', () {
      expect(rule(conditions: const {}).validate(), 'ruleNeedsCondition');
    });

    test('без названия правило не сохраняется', () {
      expect(rule(title: ' ').validate(), 'ruleTitleRequired');
    });

    test('порт: число или диапазон, иначе ошибка', () {
      expect(
        rule(conditions: const {RuleField.port: ['443']}).validate(),
        isNull,
      );
      expect(
        rule(conditions: const {RuleField.port: ['8000-9000']}).validate(),
        isNull,
      );
      expect(
        rule(conditions: const {RuleField.port: ['0']}).validate(),
        'ruleBadPort',
      );
      expect(
        rule(conditions: const {RuleField.port: ['70000']}).validate(),
        'ruleBadPort',
      );
      expect(
        rule(conditions: const {RuleField.port: ['9000-8000']}).validate(),
        'ruleBadPort',
      );
      expect(
        rule(conditions: const {RuleField.port: ['http']}).validate(),
        'ruleBadPort',
      );
    });
  });

  group('RuleStore', () {
    test('сохранённые правила читаются обратно в том же порядке', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = RuleStore(prefs);

      await store.save([
        rule(id: 'a', title: 'Первое'),
        rule(id: 'b', title: 'Второе', outbound: proxyTag),
      ]);

      final read = store.load();
      expect(read.map((item) => item.title).toList(), ['Первое', 'Второе']);
      expect(read[1].outbound, proxyTag);
    });

    test('файл с мусором читается как пустой список', () async {
      SharedPreferences.setMockInitialValues({'routing.rules.v1': '{не json'});
      final prefs = await SharedPreferences.getInstance();

      expect(RuleStore(prefs).load(), isEmpty);
    });

    test('неизвестное условие выбрасывается, а не переезжает в домены', () async {
      SharedPreferences.setMockInitialValues({
        'routing.rules.v1': jsonEncode([
          {
            'id': 'a',
            'title': 'Хром',
            'outbound': directTag,
            'conditions': {
              'processName': ['chrome.exe'],
              'domain': ['example.com'],
            },
          },
        ]),
      });
      final prefs = await SharedPreferences.getInstance();

      final read = RuleStore(prefs).load();

      expect(read.single.conditions.keys, [RuleField.domain]);
    });

    test('направление не из наших двух тегов — правило отбрасывается', () async {
      SharedPreferences.setMockInitialValues({
        'routing.rules.v1': jsonEncode([
          {
            'id': 'a',
            'title': 'Чужой путь',
            'outbound': 'some-other-outbound',
            'conditions': {'domain': ['example.com']},
          },
        ]),
      });
      final prefs = await SharedPreferences.getInstance();

      expect(RuleStore(prefs).load(), isEmpty);
    });
  });

  group('порядок применения', () {
    test('пресет идёт перед правилами пользователя, те — перед завершающим',
        () {
      final rules = ruPreset.rulesWith([rule(id: 'a'), rule(id: 'b')]);

      expect(rules, hasLength(ruPreset.rules.length + 2));
      expect(rules[ruPreset.rules.length]['domain'], ['sberbank.ru']);
    });

    test('собранный конфиг вставляет правила перед завершающим', () {
      final json = jsonDecode(
        buildConfigFromLinks(
          parseLinks(link).links,
          rules: ruPreset.rulesWith([rule(id: 'a')]),
        ),
      ) as Map<String, dynamic>;
      final rules = (json['routing'] as Map)['rules'] as List;

      expect(rules.last['outboundTag'], proxyTag);
      expect(rules[rules.length - 2]['domain'], ['sberbank.ru']);
    });

    test('правило пользователя — данные, а не адрес нашего сервиса', () {
      final json = jsonEncode(rule().toJson());

      // В сохранённом правиле нет ни схем подключений, ни чужих доменов:
      // направление выбирается из двух тегов ядра (гейт У-8).
      expect(json.contains('vless'), isFalse);
      expect(json.contains('://'), isFalse);
    });
  });

  group('приложения напрямую (R2.3)', () {
    void mockApps(Object? Function(MethodCall call) handler) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('client_vpn/tunnel'),
        (call) async => handler(call),
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('client_vpn/tunnel'),
          null,
        ),
      );
    }

    test('список приложений приходит парами пакет — название', () async {
      mockApps(
        (call) => call.method == 'listApps'
            ? [
                {'package': 'org.telegram.messenger', 'name': 'Telegram'},
                {'package': 'ru.dkbank', 'name': 'Банк'},
                {'package': 42, 'name': 'Сломанная строка'},
              ]
            : null,
      );

      final apps = await const PerAppChannel().list();

      expect(apps.map((app) => app.package).toList(), [
        'org.telegram.messenger',
        'ru.dkbank',
      ]);
    });

    test('исключения передаются нативной части списком строк', () async {
      MethodCall? sent;
      mockApps((call) {
        if (call.method == 'setExcludedApps') sent = call;
        return null;
      });

      await const PerAppChannel().write(['ru.dkbank']);

      expect(sent?.arguments, ['ru.dkbank']);
    });

    test('выбор хранится на устройстве', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await PerAppStore(prefs).save(['ru.dkbank', 'com.spotify.music']);

      expect(PerAppStore(prefs).load(), ['ru.dkbank', 'com.spotify.music']);
      expect(prefs.getStringList('routing.apps.v1'), [
        'ru.dkbank',
        'com.spotify.music',
      ]);
    });

    test('список приложений передаётся ядру при подключении', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await ProfileStore.open();
      final profile = await store.addLinks(
        name: '',
        links: parseLinks(link).links,
      );
      await store.setActive(profile.id);

      final core = CapturingCore();
      final sent = <List<String>>[];
      final state = AppState(
        store,
        core,
        settings: await SettingsStore.open(),
        configWriter: (config) async => config,
        perApps: PerAppStore(await SharedPreferences.getInstance()),
        appExclusions: (packages) async => sent.add(packages),
      );
      addTearDown(state.dispose);

      await state.setDirectApps(['ru.dkbank']);
      await state.connect();

      expect(sent, [['ru.dkbank']]);
      expect(state.directApps, ['ru.dkbank']);
    });

    test('на десктопе без нативной части подключение не падает', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await ProfileStore.open();
      final profile = await store.addLinks(
        name: '',
        links: parseLinks(link).links,
      );
      await store.setActive(profile.id);

      final core = CapturingCore();
      final state = AppState(
        store,
        core,
        settings: await SettingsStore.open(),
        configWriter: (config) async => config,
        ruleStore: RuleStore(
          await SharedPreferences.getInstance(),
        ),
      );
      addTearDown(state.dispose);

      await state.setManualRules([rule(id: 'a')]);
      await state.connect();

      final rules = ((jsonDecode(core.lastConfig!) as Map)['routing']
              as Map)['rules'] as List;
      final direct = [
        for (final item in rules)
          if ((item as Map)['outboundTag'] == directTag) item,
      ];

      expect(rules.last['outboundTag'], proxyTag);
      expect(direct.last['domain'], ['sberbank.ru']);
      final prefs = await SharedPreferences.getInstance();
      expect(RuleStore(prefs).load().single.id, 'a');
    });
  });

  group('экран правил', () {
    Future<AppState> screen(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await ProfileStore.open();
      final state = AppState(
        store,
        CapturingCore(),
        settings: await SettingsStore.open(),
        configWriter: (config) async => config,
        ruleStore: RuleStore(await SharedPreferences.getInstance()),
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(MaterialApp(home: RulesScreen(state: state)));
      return state;
    }

    testWidgets('новое правило из формы появляется в списке и в памяти',
        (tester) async {
      final state = await screen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('rule-title')), 'Банк');
      await tester.enterText(
        find.byKey(const ValueKey('rule-field-domain')),
        'sberbank.ru, geosite:category-bank-ru',
      );
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();

      expect(find.text('Банк'), findsOneWidget);
      expect(state.manualRules, hasLength(1));
      expect(state.manualRules.single.conditions[RuleField.domain], [
        'sberbank.ru',
        'geosite:category-bank-ru',
      ]);
      expect(
        RuleStore(await SharedPreferences.getInstance()).load().single.title,
        'Банк',
      );
    });

    testWidgets('правило без условия остаётся в форме с объяснением',
        (tester) async {
      await screen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('rule-title')), 'Пусто');
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();

      expect(
        find.text('Ядро не принимает правило без условия: заполните хотя бы '
            'одно поле'),
        findsOneWidget,
      );
      // Форма не закрылась: пользователь дочитывает причину и правит.
      expect(find.byKey(const ValueKey('rule-title')), findsOneWidget);
    });

    testWidgets('выключенное правило не уходит в конфиг', (tester) async {
      final state = await screen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('rule-title')), 'Банк');
      await tester.enterText(
        find.byKey(const ValueKey('rule-field-domain')),
        'sberbank.ru',
      );
      await tester.tap(find.byKey(const ValueKey('rule-save')));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(state.manualRules.single.enabled, isFalse);
      expect(ManualRule.xrayRules(state.manualRules), isEmpty);
    });
  });
}
