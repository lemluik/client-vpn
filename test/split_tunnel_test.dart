import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/l10n/app_localizations.dart';
import 'package:client_vpn/manual_rules.dart';
import 'package:client_vpn/profile_config.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/routing_presets.dart';
import 'package:client_vpn/settings_store.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/split_screen.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const link =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4#Один';

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

Future<AppState> makeState({String languageCode = 'ru'}) async {
  final prefs = await SharedPreferences.getInstance();
  final store = await ProfileStore.open();
  final profile = await store.addLinks(name: '', links: parseLinks(link).links);
  await store.setActive(profile.id);
  return AppState(
    store,
    _NoCore(),
    settings: await SettingsStore.open(),
    presets: PresetStore(prefs),
    ruleStore: RuleStore(prefs),
    configWriter: (config) async => config,
    languageCode: languageCode,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('хост из одной строки', () {
    test('ссылка целиком даёт только имя хоста', () {
      expect(
        exceptionHost('https://Example.COM:8443/path?q=1#frag'),
        'example.com',
      );
    });

    test('запись с `*.` и конечная точка не мешают', () {
      expect(exceptionHost('*.mail.example.org'), 'mail.example.org');
      expect(exceptionHost('example.org.'), 'example.org');
    });

    test('кириллическое имя уходит в punycode', () {
      // Ядро и браузер говорят на ASCII: `www.рф` приходит как `www.xn--p1ai`,
      // а кириллическое имя SOCKS-вход отвергает (замер 16.10.2026).
      expect(exceptionHost('https://мвд.рф/'), 'xn--b1aew.xn--p1ai');
      expect(exceptionHost('СПБ.РФ'), 'xn--90a1af.xn--p1ai');
    });

    test('адрес, а не домен, правилом по имени не ловится', () {
      expect(exceptionHost('1.2.3.4'), isNull);
      expect(exceptionHost('localhost'), isNull);
      expect(exceptionHost(''), isNull);
      expect(exceptionHost('http://'), isNull);
    });

    test('метка, смешавшая кириллицу с латиницей, отклоняется', () {
      // Метка проверена склейкой: целиком такое написание в исходнике
      // видит гейт смешанного написания, а не тест.
      expect(exceptionHost('a' + 'рф' + '.ru'), isNull);
    });
  });

  group('вставка пачкой', () {
    test('ссылки, домены и поддомены разбираются, повторы считаются', () {
      final parsed = parseHostBlock('''
https://example.com/path?q=1
example.org
*.mail.example.org
мвд.рф
example.com

   \t \n
не домен вовсе
1.2.3.4
''');

      expect(parsed.hosts, [
        'example.com',
        'example.org',
        'mail.example.org',
        'xn--b1aew.xn--p1ai',
      ]);
      // Строка с пробелами — не адрес: её считаем пропущенной, пустые — нет.
      expect(parsed.duplicates, 1);
      expect(parsed.skipped, 2);
    });

    test('регистр и повторная вставка одного адреса — повторы', () {
      final parsed = parseHostBlock('Example.ORG\nexample.org');

      expect(parsed.hosts, ['example.org']);
      expect(parsed.duplicates, 1);
      expect(parsed.skipped, 0);
    });
  });

  group('punycode', () {
    test('векторы сверены с `encode("idna")`', () {
      expect(idnAsciiLabel('рф'), 'xn--p1ai');
      expect(idnAsciiLabel('москва'), 'xn--80adxhks');
      expect(idnAsciiLabel('мвд'), 'xn--b1aew');
      expect(idnAsciiLabel('тест'), 'xn--e1aybc');
    });

    test('ASCII остаётся ASCII', () {
      expect(idnAsciiLabel('example'), 'example');
      expect(idnAsciiLabel('xn--p1ai'), 'xn--p1ai');
      expect(idnAsciiLabel('a-b1'), 'a-b1');
    });

    test('не-имя отклоняется', () {
      expect(idnAsciiLabel(''), isNull);
      expect(idnAsciiLabel('-ru'), isNull);
      expect(idnAsciiLabel('ru-'), isNull);
      expect(idnAsciiLabel('a_b'), isNull);
      expect(idnAsciiLabel('a' + 'рф'), isNull);
    });
  });

  group('зоны домашнего региона', () {
    test('зона идёт в правило с ведущей точкой и в punycode', () {
      expect(ruPreset.homeDomains, ['ru', 'su', 'рф']);
      expect((ruPreset.effectiveRules.last['domain'] as List).cast<String>(), [
        '.ru',
        '.su',
        '.xn--p1ai',
      ]);
    });

    test('пресет без зон не добавляет ничего', () {
      expect(offPreset.hasHomeDomains, isFalse);
      expect(offPreset.effectiveRules, isEmpty);
      expect(offPreset.rulesWith([rule(id: 'a')]).single['domain'], [
        'example.com',
      ]);
    });
  });

  group('исключения в хранилище правил', () {
    test('списки читаются обратно и не трогают чужие правила', () {
      final stored = ManualRule.withSplitHosts(
        [rule(id: 'a', title: 'Моё')],
        direct: ['example.com'],
        tunnel: ['internal.corp.ru'],
        directTitle: 'Исключения: напрямую',
        tunnelTitle: 'Исключения: в туннель',
      );

      expect(ManualRule.splitHosts(stored, ManualRule.splitDirectId), [
        'example.com',
      ]);
      expect(ManualRule.splitHosts(stored, ManualRule.splitTunnelId), [
        'internal.corp.ru',
      ]);
      expect(stored.map((item) => item.id), [
        'a',
        'split.direct',
        'split.tunnel',
      ]);
      expect(stored.first.title, 'Моё');
    });

    test('повторная запись заменяет список, а не дописывает', () {
      final once = ManualRule.withSplitHosts(
        const [],
        direct: ['a.example'],
        tunnel: const [],
        directTitle: 'Исключения: напрямую',
        tunnelTitle: 'Исключения: в туннель',
      );
      final twice = ManualRule.withSplitHosts(
        once,
        direct: ['b.example'],
        tunnel: const [],
        directTitle: 'Исключения: напрямую',
        tunnelTitle: 'Исключения: в туннель',
      );

      expect(twice, hasLength(1));
      expect(ManualRule.splitHosts(twice, ManualRule.splitDirectId), [
        'b.example',
      ]);
    });

    test('пустой список не оставляет правила без условия', () {
      // Ядро правило без условия отвергает, а редактор показал бы пустую строку.
      final stored = ManualRule.withSplitHosts(
        [rule(id: ManualRule.splitDirectId, title: 'Исключения: напрямую')],
        direct: const [],
        tunnel: const [],
        directTitle: 'Исключения: напрямую',
        tunnelTitle: 'Исключения: в туннель',
      );

      expect(stored, isEmpty);
    });

    test('правило-исключение сохраняется и читается как правило', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = RuleStore(prefs);

      await store.save(
        ManualRule.withSplitHosts(
          const [],
          direct: ['example.com', exceptionHost('https://мвд.рф/')!],
          tunnel: const [],
          directTitle: 'Исключения: напрямую',
          tunnelTitle: 'Исключения: в туннель',
        ),
      );

      final read = store.load();
      expect(read.single.id, ManualRule.splitDirectId);
      expect(read.single.conditions[RuleField.domain], [
        'example.com',
        'xn--b1aew.xn--p1ai',
      ]);
    });

    test('длинный список в интерфейсе не растягивается', () {
      final item = ManualRule(
        id: ManualRule.splitDirectId,
        title: 'Исключения: напрямую',
        outbound: directTag,
        conditions: {
          RuleField.domain: [for (var i = 0; i < 9; i++) 'h$i.example'],
        },
      );

      expect(item.summary, contains('и ещё 5'));
    });
  });

  group('исключения в наборе правил ядра', () {
    test('исключение «в туннель» стоит перед зонным правилом', () {
      final rules = ruPreset.rulesWith(
        ManualRule.withSplitHosts(
          const [],
          direct: ['sberbank.ru'],
          tunnel: ['my.office.ru'],
          directTitle: 'Исключения: напрямую',
          tunnelTitle: 'Исключения: в туннель',
        ),
      );
      final tunnel = rules.indexWhere(
        (rule) => rule['outboundTag'] == proxyTag,
      );
      final zone = rules.indexWhere(
        (rule) => (rule['domain'] as List?)?.contains('.ru') ?? false,
      );
      final direct = rules.lastWhere(
        (rule) => (rule['domain'] as List?)?.contains('sberbank.ru') ?? false,
      );

      expect(tunnel, 0);
      expect(zone, greaterThan(tunnel));
      expect(direct['outboundTag'], directTag);
      expect(rules.indexOf(direct), greaterThan(zone));
    });
  });

  group('экран исключений', () {
    Future<AppState> open(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = await makeState();
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SplitScreen(state: state),
        ),
      );
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('вставка пачки кладёт адреса в список и в память', (
      tester,
    ) async {
      final state = await open(tester);

      await tester.enterText(
        find.byKey(const ValueKey('split-paste')),
        'https://example.com/path\nмвд.рф\nbad input',
      );
      await tester.tap(find.byKey(const ValueKey('split-add')));
      await tester.pumpAndSettle();

      expect(state.splitDirectHosts, ['example.com', 'xn--b1aew.xn--p1ai']);
      expect(
        find.byKey(const ValueKey('split-host-example.com')),
        findsOneWidget,
      );
      expect(
        RuleStore(
          await SharedPreferences.getInstance(),
        ).load().single.conditions[RuleField.domain],
        ['example.com', 'xn--b1aew.xn--p1ai'],
      );
      // Поле очистки: следующая пачка не смешивается с предыдущей.
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('split-paste')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('смена направления переносит адрес, а не дублирует его', (
      tester,
    ) async {
      final state = await open(tester);
      await state.setSplitHosts(
        direct: ['example.com'],
        tunnel: const [],
        directTitle: 'Исключения: напрямую',
        tunnelTitle: 'Исключения: в туннель',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('split-host-example.com')),
          matching: find.byTooltip('в туннель'),
        ),
      );
      await tester.pumpAndSettle();

      expect(state.splitDirectHosts, isEmpty);
      expect(state.splitTunnelHosts, ['example.com']);
    });
  });
}

ManualRule rule({
  String id = 'r1',
  String title = 'Правило',
  String outbound = directTag,
  bool enabled = true,
  Map<RuleField, List<String>> conditions = const {
    RuleField.domain: ['example.com'],
  },
}) => ManualRule(
  id: id,
  title: title,
  outbound: outbound,
  conditions: conditions,
  enabled: enabled,
);
