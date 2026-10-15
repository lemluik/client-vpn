import 'dart:convert';

import 'package:client_vpn/tun_config.dart';
import 'package:flutter_test/flutter_test.dart';

const userConfig = '''
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"listen": "127.0.0.1", "port": 10808, "protocol": "socks", "tag": "local-socks"},
    {"listen": "127.0.0.1", "port": 10809, "protocol": "http", "tag": "local-http"}
  ],
  "outbounds": [
    {"protocol": "vless", "settings": {"vnext": [{"address": "example.org", "port": 443}]}, "tag": "proxy"}
  ]
}
''';

Map<String, dynamic> build(String source) =>
    jsonDecode(buildTunConfig(source)) as Map<String, dynamic>;

void main() {
  group('buildTunConfig', () {
    test('заменяет локальные inbound на tun', () {
      final inbounds = build(userConfig)['inbounds'] as List;

      expect(inbounds, hasLength(1));
      expect(inbounds.single['protocol'], 'tun');
      expect(inbounds.single['tag'], 'tun-in');
      expect((inbounds.single['settings'] as Map)['MTU'], 1500);
    });

    test('сохраняет исходящие серверы пользователя', () {
      final outbounds = build(userConfig)['outbounds'] as List;

      expect(outbounds, hasLength(1));
      expect(outbounds.single['protocol'], 'vless');
      expect(outbounds.single['tag'], 'proxy');
    });

    test('завершающее правило отправляет весь трафик в прокси', () {
      final rules = (build(userConfig)['routing'] as Map)['rules'] as List;

      expect(rules.last, {
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': 'proxy',
      });
    });

    test('дописывает тег, если у прокси его не было', () {
      const source = '{"outbounds":[{"protocol":"trojan","settings":{}}]}';
      final result = build(source);
      final rules = (result['routing'] as Map)['rules'] as List;

      expect((result['outbounds'] as List).single['tag'], 'cvpn-proxy');
      expect((rules.last as Map)['outboundTag'], 'cvpn-proxy');
    });

    test('правила пользователя идут раньше завершающего', () {
      const source = '''
      {
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
          {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}
        ]},
        "outbounds": [
          {"protocol": "freedom", "tag": "direct"},
          {"protocol": "vless", "tag": "proxy"}
        ]
      }
      ''';
      final routing = build(source)['routing'] as Map;
      final rules = routing['rules'] as List;

      expect(routing['domainStrategy'], 'AsIs');
      expect(rules, hasLength(2));
      expect((rules.first as Map)['outboundTag'], 'direct');
      expect((rules.last as Map)['outboundTag'], 'proxy');
    });

    test('прокси ищется не только в первом outbound', () {
      const source = '''
      {
        "outbounds": [
          {"protocol": "blackhole", "tag": "block"},
          {"protocol": "vmess", "tag": "proxy"}
        ]
      }
      ''';
      final rules = (build(source)['routing'] as Map)['rules'] as List;

      expect((rules.last as Map)['outboundTag'], 'proxy');
    });

    test('конфиг без прокси отклоняется', () {
      const source = '{"outbounds":[{"protocol":"freedom","tag":"direct"}]}';

      expect(
        () => buildTunConfig(source),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'текст',
            contains('нет исходящего прокси-сервера'),
          ),
        ),
      );
    });

    test('пустые outbounds отклоняются', () {
      expect(
        () => buildTunConfig('{"outbounds":[]}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('документ не объект отклоняется', () {
      expect(
        () => buildTunConfig('[1, 2]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('нечитаемый JSON отклоняется', () {
      expect(() => buildTunConfig('{'), throwsA(isA<FormatException>()));
    });
  });

  group('блоки, которые ядро читает отдельно от маршрутизации', () {
    const withExtras = '''
    {
      "outbounds": [{"protocol": "vless", "tag": "proxy"}],
      "routing": {"rules": []},
      "dns": {"servers": ["1.1.1.1"]},
      "policy": {"levels": {"0": {"handshake": 4}}},
      "observatory": {"enableMemoryStats": true, "subjectFrequency": {
        "enabled": true, "target": "https://www.gstatic.com/generate_204",
        "timeout": "1s", "frequency": "5m"}},
      "burstObservatory": {"maxParallelism": 4, "pingConfig": {
        "mode": "connect", "timeout": "5s", "frequency": "30s",
        "targets": ["https://www.gstatic.com/generate_204"]}}
    }
    ''';

    test(
        'dns, policy, observatory и burstObservatory переходят в туннельный конфиг',
        () {
      final result = build(withExtras);

      expect(result['dns'], {
        'servers': ['1.1.1.1'],
      });
      expect(result['policy'], {
        'levels': {
          '0': {'handshake': 4},
        },
      });
      expect((result['observatory'] as Map)['enableMemoryStats'], true);
      expect((result['burstObservatory'] as Map)['maxParallelism'], 4);
    });

    test('балансировщик остаётся внутри routing — только там его читает ядро',
        () {
      const source = '''
      {
        "outbounds": [{"protocol": "vless", "tag": "proxy-a"}],
        "routing": {
          "balancers": [{"tag": "lb", "selector": ["proxy-a"]}],
          "rules": [{"type": "field", "network": "tcp,udp", "balancerTag": "lb"}]
        }
      }
      ''';
      final routing = build(source)['routing'] as Map;

      expect(routing['balancers'], hasLength(1));
      expect(routing['rules'][0],
          {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'lb'},);
      // завершающее «всё в прокси» дописывается после правил пользователя
      expect((routing['rules'].last as Map)['outboundTag'], 'proxy-a');
    });

    test('балансировщик верхним уровнем в конфиг туннеля не попадает', () {
      const source = '''
      {
        "outbounds": [{"protocol": "vless", "tag": "proxy"}],
        "balancers": [{"tag": "lb", "selector": ["proxy"]}]
      }
      ''';

      expect(build(source).containsKey('balancers'), false);
    });

    test('отсутствующие блоки не добавляются пустыми', () {
      final result = build(userConfig);

      expect(result.containsKey('dns'), false);
      expect(result.containsKey('observatory'), false);
      expect(result.containsKey('burstObservatory'), false);
      expect(result.containsKey('policy'), false);
    });
  });

  group('tunConfigForTest', () {
    test('заменяет tun inbound на локальный socks, остальное не трогает', () {
      const source = '''
      {
        "outbounds": [{"protocol": "vless", "tag": "proxy"}],
        "dns": {"servers": ["1.1.1.1"]},
        "routing": {"balancers": [{"tag": "lb", "selector": ["proxy"]}],
                    "rules": [{"type": "field", "network": "tcp,udp", "balancerTag": "lb"}]}
      }
      ''';
      final forTest = jsonDecode(tunConfigForTest(buildTunConfig(source)))
          as Map<String, dynamic>;
      final inbounds = forTest['inbounds'] as List;

      expect(inbounds, hasLength(1));
      expect(inbounds.single['protocol'], 'socks');
      expect(inbounds.single['listen'], '127.0.0.1');
      expect(forTest['dns'], {
        'servers': ['1.1.1.1'],
      });
      expect((forTest['routing'] as Map)['balancers'], hasLength(1));
      expect((forTest['outbounds'] as List).single['tag'], 'proxy');
    });

    test('нечитаемый конфиг туннеля отклоняется', () {
      expect(() => tunConfigForTest('['), throwsA(isA<FormatException>()));
    });

    test('снифинг с tun-входа переносится в проверочный вход', () {
      const source = '{"outbounds": [{"protocol": "vless", "tag": "proxy"}]}';
      final forTest =
          jsonDecode(tunConfigForTest(buildTunConfig(source))) as Map;
      final tun = jsonDecode(buildTunConfig(source)) as Map;
      final tunSniffing = ((tun['inbounds'] as List).first as Map)['sniffing'];

      expect(((forTest['inbounds'] as List).first as Map)['sniffing'],
          tunSniffing,);
    });
  });

  group('tunInbound', () {
    test('sniffing включён для http и tls', () {
      final sniffing = tunInbound()['sniffing'] as Map<String, dynamic>;

      expect(sniffing['enabled'], true);
      expect(sniffing['destOverride'], ['http', 'tls']);
    });
  });
}
