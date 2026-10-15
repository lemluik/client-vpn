import 'dart:convert';

import 'package:client_vpn/failover.dart';
import 'package:client_vpn/profile_config.dart';
import 'package:client_vpn/share_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Две ссылки стороннего вида: адреса из документации, не боевой узел.
const firstLink =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4'
    '#%D0%9F%D0%B5%D1%80%D0%B2%D1%8B%D0%B9%201';

const secondLink =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000002@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4'
    '#%D0%9F%D0%B5%D1%80%D0%B2%D1%8B%D0%B9%202';

List<ShareLink> parsed() => [
  parseShareLink(firstLink),
  parseShareLink(secondLink),
];

void main() {
  group('точка проб', () {
    test('значение по умолчанию нейтральное и рабочее', () {
      expect(defaultProbeEndpoint, startsWith('https://'));
      expect(probeEndpointError(defaultProbeEndpoint), isNull);
    });

    test('принимаются только http и https с хостом', () {
      expect(probeEndpointError('https://example.com/generate_204'), isNull);
      expect(probeEndpointError(' http://example.com '), isNull);
      expect(probeEndpointError(''), isNotNull);
      expect(probeEndpointError('example.com'), isNotNull);
      expect(probeEndpointError('ftp://example.com'), isNotNull);
      expect(probeEndpointError('https://'), isNotNull);
    });

    test('сохранённая точка проб читается, битая — нет', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ProbeStore(await SharedPreferences.getInstance());
      expect(store.load(), defaultProbeEndpoint);

      await store.save('https://example.com/generate_204');
      expect(store.load(), 'https://example.com/generate_204');

      await store.save('not a url');
      expect(store.load(), defaultProbeEndpoint);
    });
  });

  group('балансировщик региона', () {
    test('из одного узла не строится', () {
      expect(regionBalancers(const ['cvpn-proxy']), isEmpty);
      expect(regionBalancers(const []), isEmpty);
    });

    test('два узла — один балансировщик со стратегией leastPing', () {
      final balancers = regionBalancers([tagForProfile(0), tagForProfile(1)]);

      expect(balancers, hasLength(1));
      final balancer = balancers.first;
      expect(balancer['tag'], regionBalancerTag);
      expect(balancer['selector'], ['cvpn-proxy', 'cvpn-proxy-2']);
      expect((balancer['strategy'] as Map)['type'], 'leastPing');
    });

    test(
      'порог прилипания и запасной путь на прямое подключение не ставятся',
      () {
        final settings =
            ((regionBalancers(const ['a', 'b']).first['strategy']
                    as Map)['settings'])
                as Object?;

        // tolerance = порог прилипания: число нужно измерить на стенде.
        expect(settings, isNull);
        expect(
          regionBalancers(const ['a', 'b']).first.containsKey('fallbackTag'),
          false,
        );
      },
    );
  });

  group('наблюдатель', () {
    test('leastPing требует observatory с target', () {
      expect(observatoryFor('https://example.com'), {
        'target': 'https://example.com',
      });
    });

    test('leastLoad требует burstObservatory с pingConfig.targets', () {
      expect(burstObservatoryFor('https://example.com'), {
        'pingConfig': {
          'targets': ['https://example.com'],
        },
      });
    });
  });

  group('конфиг из ссылок с балансировщиком', () {
    test('наблюдатель и balancerTag попадают в конфиг', () {
      final links = parsed();
      final balancers = regionBalancers([
        for (final (index, _) in links.indexed) tagForProfile(index),
      ]);
      final config =
          jsonDecode(
                buildConfigFromLinks(
                  links,
                  balancers: balancers,
                  observatory: observatoryFor(defaultProbeEndpoint),
                ),
              )
              as Map<String, dynamic>;

      expect(config['observatory'], {'target': defaultProbeEndpoint});
      expect(config.containsKey('burstObservatory'), false);
      final routing = config['routing'] as Map<String, dynamic>;
      expect(routing['balancers'], balancers);
      expect(
        (routing['rules'] as List).last,
        containsPair('balancerTag', regionBalancerTag),
      );
    });

    test('один узел — конфига без наблюдателя', () {
      final balancers = regionBalancers([tagForProfile(0)]);
      final config =
          jsonDecode(
                buildConfigFromLinks(
                  [parsed().first],
                  balancers: balancers,
                  observatory: balancers.isEmpty
                      ? null
                      : observatoryFor(defaultProbeEndpoint),
                ),
              )
              as Map<String, dynamic>;

      expect(config.containsKey('observatory'), false);
      expect(
        ((config['routing'] as Map)['rules'] as List).last,
        containsPair('outboundTag', proxyTag),
      );
    });
  });
}
