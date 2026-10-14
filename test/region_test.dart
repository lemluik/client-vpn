import 'dart:convert';

import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/region.dart';
import 'package:client_vpn/share_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ссылка на узел: порт различает профили, имя задаёт регион.
String node(int port, String remark) =>
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:$port'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#${Uri.encodeComponent(remark)}';

/// Подписка двух регионов: строки региона идут подряд, порядок — приоритет.
final twoRegions = parseLinks(
  [
    node(443, 'Europe relay 1'),
    node(8443, 'Europe relay 2'),
    node(2053, 'Kyrgyzstan relay 1'),
    node(2096, 'Kyrgyzstan direct'),
  ].join('\n'),
).links;

/// Профили без имени: провайдер не прислал якорь, имя заменено адресом.
final nameless = parseLinks([node(443, ''), node(2053, '')].join('\n')).links;

int portOf(Map<String, dynamic> outbound) =>
    (outbound['settings']['vnext'][0] as Map)['port'] as int;

List<int> portsOf(String configJson) {
  final outbounds = (jsonDecode(configJson)['outbounds'] as List)
      .cast<Map<String, dynamic>>();
  return outbounds
      .where((outbound) => outbound['protocol'] == 'vless')
      .map(portOf)
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('метка региона', () {
    test('берётся первое слово имени узла', () {
      expect(regionLabelOf('EU-РФ1'), 'EU');
      expect(regionLabelOf('Кыргызстан 2'), 'Кыргызстан');
      expect(regionLabelOf('🇩🇪 Germany 01 | Premium'), 'Germany');
    });

    test('имя из цифр и пустое имя региона не дают', () {
      expect(regionLabelOf('01'), isEmpty);
      expect(regionLabelOf(''), isEmpty);
    });
  });

  group('список регионов', () {
    test('группирует по имени и сохраняет порядок подписки', () {
      final regions = regionsOf(twoRegions);

      expect(regions.map((region) => region.key), ['europe', 'kyrgyzstan']);
      expect(regions.map((region) => region.label), [
        'Europe',
        'Kyrgyzstan',
      ]);
      expect(regions.first.links.map((link) => link.port), [443, 8443]);
      expect(regions.last.links.map((link) => link.port), [2053, 2096]);
    });

    test('без имён провайдера регион один и выбор не предлагается', () {
      final regions = regionsOf(nameless);

      expect(regions, hasLength(1));
      expect(regions.single.key, unnamedRegionKey);
      expect(regions.single.label, unnamedRegionLabel);
      expect(regions.single.links, hasLength(2));
    });

    test('поиск по метке: ключ — метка в нижнем регистре, чужой метки нет', () {
      final regions = regionsOf(twoRegions);

      expect(regions.last.key, regions.last.label.toLowerCase());
      expect(regionByKey(regions, 'kyrgyzstan')?.label, 'Kyrgyzstan');
      expect(regionByKey(regions, null), isNull);
      expect(regionByKey(regions, ''), isNull);
      expect(regionByKey(regions, 'uk'), isNull);
    });
  });

  group('конфиг ядра по выбранному региону', () {
    test('по умолчанию работает первый регион подписки', () async {
      final store = await ProfileStore.open();
      await store.addLinks(name: 'Подписка', links: twoRegions);

      expect(portsOf(store.activeConfig().json), [443, 8443]);
    });

    test('выбор региона оставляет в конфиге только его профили', () async {
      final store = await ProfileStore.open();
      final profile = await store.addLinks(name: 'Подписка', links: twoRegions);

      await store.setRegion(profile.id, 'kyrgyzstan');

      expect(portsOf(store.activeConfig().json), [2053, 2096]);
      expect(store.active?.region, 'kyrgyzstan');
    });

    test('выбранный регион переживает перезапуск приложения', () async {
      final store = await ProfileStore.open();
      final profile = await store.addLinks(name: 'Подписка', links: twoRegions);
      await store.setRegion(profile.id, 'kyrgyzstan');

      final reopened = await ProfileStore.open();

      expect(reopened.active?.region, 'kyrgyzstan');
      expect(portsOf(reopened.activeConfig().json), [2053, 2096]);
    });

    test('чужая метка региона отвергается', () async {
      final store = await ProfileStore.open();
      final profile = await store.addLinks(name: 'Подписка', links: twoRegions);

      expect(
        () => store.setRegion(profile.id, 'us'),
        throwsA(isA<FormatException>()),
      );
      expect(store.active?.region, isNull);
    });

    test('исчезнувший из подписки регион откатывается на первый', () {
      final profile = StoredProfile(
        id: 'test',
        name: 'Подписка',
        kind: ProfileKind.subscription,
        addedAt: DateTime.utc(2026, 10, 14),
        links: twoRegions,
        region: 'uk',
      );

      expect(linksOfProfile(profile).map((link) => link.port), [443, 8443]);
    });
  });
}
