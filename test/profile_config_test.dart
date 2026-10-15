import 'dart:convert';

import 'package:client_vpn/profile_config.dart';
import 'package:client_vpn/proxy_config.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/tun_config.dart';
import 'package:flutter_test/flutter_test.dart';

const firstLink = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4'
    '#%D0%9F%D0%B5%D1%80%D0%B2%D1%8B%D0%B9';

const secondLink = 'trojan://pass@example.org:8443?sni=example.org#Second';

List<ShareLink> parsedLinks() => parseLinks('$firstLink\n$secondLink').links;

Map<String, dynamic> decode(String config) =>
    jsonDecode(config) as Map<String, dynamic>;

List<dynamic> outboundsOf(String config) =>
    decode(config)['outbounds'] as List<dynamic>;

List<dynamic> rulesOf(String config) =>
    (decode(config)['routing'] as Map)['rules'] as List<dynamic>;

void main() {
  group('buildConfigFromLinks', () {
    test('собирает локальную точку входа для системного прокси', () {
      final config = decode(buildConfigFromLinks(parsedLinks()));
      final inbounds = config['inbounds'] as List;

      expect(inbounds, hasLength(2));
      expect(inbounds[0]['protocol'], 'http');
      expect(inbounds[0]['listen'], '127.0.0.1');
      expect(inbounds[0]['port'], defaultHttpPort);
      expect(inbounds[1]['protocol'], 'socks');
      expect(inbounds[1]['port'], defaultSocksPort);
      expect((inbounds[1]['settings'] as Map)['udp'], isTrue);
    });

    test('даёт каждому профилю свой тег и оставляет выход напрямую', () {
      final outbounds = outboundsOf(buildConfigFromLinks(parsedLinks()));

      expect(outbounds, hasLength(3));
      expect(outbounds[0]['protocol'], 'vless');
      expect(outbounds[0]['tag'], proxyTag);
      expect(outbounds[1]['protocol'], 'trojan');
      expect(outbounds[1]['tag'], '$proxyTag-2');
      expect(outbounds[2]['protocol'], 'freedom');
      expect(outbounds[2]['tag'], directTag);
    });

    test('завершающее правило уводит весь трафик в прокси', () {
      final config = decode(buildConfigFromLinks(parsedLinks()));
      final routing = config['routing'] as Map;
      final last = rulesOf(buildConfigFromLinks(parsedLinks())).last as Map;

      expect(routing['domainStrategy'], 'AsIs');
      expect(last['type'], 'field');
      expect(last['network'], 'tcp,udp');
      expect(last['outboundTag'], proxyTag);
    });

    test('правила пользователя встают до завершающего', () {
      final config = buildConfigFromLinks(
        parsedLinks(),
        rules: const [
          {
            'type': 'field',
            'domain': ['geosite:ru'],
            'outboundTag': directTag,
          },
        ],
      );
      final rules = rulesOf(config);

      expect(rules, hasLength(2));
      expect((rules.first as Map)['domain'], ['geosite:ru']);
      expect((rules.first as Map)['outboundTag'], directTag);
      expect((rules.last as Map)['outboundTag'], proxyTag);
    });

    test('порты задаются вызывающей стороной', () {
      final config = buildConfigFromLinks(
        parsedLinks().take(1),
        httpPort: 2080,
        socksPort: 2081,
      );

      expect(parseProxyInbound(config)?.port, 2080);
    });

    test('системный прокси находит точку входа в собранном конфиге', () {
      final endpoint = parseProxyInbound(buildConfigFromLinks(parsedLinks()));

      expect(endpoint?.protocol, 'http');
      expect(endpoint?.port, defaultHttpPort);
    });

    test('собранный конфиг пригоден для Android-пути', () {
      final tun = decode(buildTunConfig(buildConfigFromLinks(parsedLinks())));
      final inbounds = tun['inbounds'] as List;
      final rules = (tun['routing'] as Map)['rules'] as List;
      final last = rules.last as Map;

      expect(inbounds.single['protocol'], 'tun');
      expect(inbounds.single['tag'], 'tun-in');
      expect(last['outboundTag'], proxyTag);
      expect((tun['outbounds'] as List).map((o) => o['protocol']), [
        'vless',
        'trojan',
        'freedom',
      ]);
    });

    test('пустой список профилей отклоняется', () {
      expect(
        () => buildConfigFromLinks(const []),
        throwsA(isA<LinkFormatException>()),
      );
    });
  });

  group('tagForProfile', () {
    test('первый профиль получает основной тег', () {
      expect(tagForProfile(0), proxyTag);
      expect(tagForProfile(1), '$proxyTag-2');
      expect(tagForProfile(9), '$proxyTag-10');
    });
  });

  group('balancerTagFor', () {
    test('находит балансировщик, которому доверен тег', () {
      expect(
        balancerTagFor([
          {'tag': 'lb-other', 'selector': ['cvpn-proxy-2']},
          {'tag': 'lb', 'selector': [proxyTag, 'cvpn-proxy-2']},
        ], proxyTag),
        'lb',
      );
    });

    test('балансировщик без тега и без узла в selector не подходит', () {
      expect(balancerTagFor([{'selector': [proxyTag]}], proxyTag), isNull);
      expect(balancerTagFor([{'tag': 'lb', 'selector': ['other']}], proxyTag),
          isNull);
      expect(balancerTagFor(null, proxyTag), isNull);
      expect(balancerTagFor(const [], proxyTag), isNull);
    });
  });

  group('завершающее правило при объявленном балансировщике', () {
    const balancers = [
      {'tag': 'lb', 'selector': [proxyTag, '$proxyTag-2']},
    ];

    test('ссылается на балансировщик, а не на первое исходящее соединение', () {
      final config = decode(
        buildConfigFromLinks(parsedLinks(), balancers: balancers),
      );
      final routing = config['routing'] as Map;

      expect(routing['balancers'], balancers);
      expect(routing['rules'].last, {
        'type': 'field',
        'network': 'tcp,udp',
        'balancerTag': 'lb',
      });
    });

    test('без балансировщиков правило остаётся на метке прокси', () {
      expect(terminalRule(proxyTag), {
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': proxyTag,
      });
    });

    test('балансировщик не уходит верхним уровнем', () {
      final config = decode(
        buildConfigFromLinks(parsedLinks(), balancers: balancers),
      );

      expect(config.containsKey('balancers'), false);
    });
  });
}
