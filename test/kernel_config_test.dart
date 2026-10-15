import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/profile_config.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/tun_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Две ссылки стороннего вида: адреса из документации, не боевой узел.
const firstLink = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4'
    '#%D0%9F%D0%B5%D1%80%D0%B2%D1%8B%D0%B9';

const secondLink = 'trojan://pass@example.org:8443?sni=example.org#Second';

/// Проверка собранных конфигов настоящим ядром, а не только структурой.
///
/// Прогон идёт `xray run -test` — тот же режим, что вызывает приложение перед
/// запуском. Тест пропускается, если ядро или geo-базы не скачаны
/// (`bash scripts/download_xray.sh`), чтобы `flutter test` не зависел от сети.
void main() {
  final xray = File(p.join('assets', 'xray', 'xray.exe'));
  final geoip = File(p.join('assets', 'xray', 'geoip.dat'));
  final geosite = File(p.join('assets', 'xray', 'geosite.dat'));
  final ready = xray.existsSync() && geoip.existsSync() && geosite.existsSync();
  const reason = 'ядро или geo-базы не скачаны: bash scripts/download_xray.sh';

  Future<ProcessResult> testConfig(String json) async {
    final dir = await Directory.systemTemp.createTemp('cvpn-kernel-test');
    final file = File(p.join(dir.path, 'config.json'));
    await file.writeAsString(json, flush: true);
    try {
      return await Process.run(
        xray.absolute.path,
        ['run', '-test', '-config', file.path],
        workingDirectory: p.dirname(xray.absolute.path),
        environment: {'XRAY_LOCATION_ASSET': p.dirname(xray.absolute.path)},
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }

  String output(ProcessResult result) =>
      '${result.stdout}\n${result.stderr}'.trim();

  Map<String, dynamic> configWith(
    Map<String, dynamic> extra, {
    Map<String, dynamic>? balancer,
  }) =>
      {
        'log': {'loglevel': 'warning'},
        'inbounds': [
          {
            'listen': '127.0.0.1',
            'port': 10810,
            'protocol': 'socks',
            'settings': {'udp': true},
            'tag': 'test-in',
          }
        ],
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'example.com',
                  'port': 443,
                  'users': [
                    {
                      'id': '00000000-0000-0000-0000-000000000000',
                      'encryption': 'none',
                    }
                  ],
                }
              ],
            },
            'tag': 'proxy-a',
          },
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'example.org',
                  'port': 443,
                  'users': [
                    {
                      'id': '00000000-0000-0000-0000-000000000001',
                      'encryption': 'none',
                    }
                  ],
                }
              ],
            },
            'tag': 'proxy-b',
          },
          {'protocol': 'freedom', 'tag': 'cvpn-direct'},
        ],
        'routing': {
          'domainStrategy': 'AsIs',
          'rules': [
            {
              'type': 'field',
              'ip': ['geoip:ru'],
              'outboundTag': 'cvpn-direct',
            },
            {
              'type': 'field',
              'network': 'tcp,udp',
              'balancerTag': 'lb',
            },
          ],
          'balancers': [
            balancer ??
                {
                  'tag': 'lb',
                  'selector': ['proxy-a', 'proxy-b'],
                },
          ],
        },
        ...extra,
      };

  group('ядро принимает собранные конфиги', () {
    test(
      'балансировщик в routing плюс наблюдатель, dns и policy',
      () async {
        final config = configWith(
          {
            'dns': {
              'servers': ['1.1.1.1'],
            },
            'policy': {
              'levels': {
                '0': {'handshake': 4},
              },
            },
            'observatory': {
              'enableMemoryStats': true,
              'subjectFrequency': {
                'enabled': true,
                'target': 'https://www.gstatic.com/generate_204',
                'timeout': '1s',
                'frequency': '5m',
              },
            },
            'burstObservatory': {
              'maxParallelism': 4,
              'pingConfig': {
                'mode': 'connect',
                'timeout': '5s',
                'frequency': '30s',
                'targets': ['https://www.gstatic.com/generate_204'],
              },
            },
          },
          balancer: {
            'tag': 'lb',
            'selector': ['proxy-a', 'proxy-b'],
            'strategy': {'type': 'leastPing'},
            'fallbackTag': 'cvpn-direct',
          },
        );
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, 0, reason: output(result));
      },
      skip: ready ? false : reason,
    );

    test(
      'leastLoad с burstObservatory и протокольным снифингом',
      () async {
        final config = configWith(
          {
            'burstObservatory': {
              'maxParallelism': 2,
              'pingConfig': {
                'mode': 'connect',
                'timeout': '5s',
                'frequency': '3m',
                'targets': ['https://www.gstatic.com/generate_204'],
              },
            },
          },
          balancer: {
            'tag': 'lb',
            'selector': ['proxy-a', 'proxy-b'],
            'strategy': {
              'type': 'leastLoad',
              'settings': {'expected': 1, 'maxRTT': '2s', 'tolerance': 0.1},
            },
            'fallbackTag': 'cvpn-direct',
          },
        );
        ((config['inbounds'] as List).first as Map)['sniffing'] = {
          'enabled': true,
          'destOverride': ['http', 'tls'],
        };
        (config['routing'] as Map)['rules'] = [
          {
            'type': 'field',
            'protocol': ['http'],
            'outboundTag': 'cvpn-direct',
          },
          {
            'type': 'field',
            'network': 'tcp,udp',
            'balancerTag': 'lb',
          },
        ];
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, 0, reason: output(result));
      },
      skip: ready ? false : reason,
    );

    test(
      'туннельный конфиг, собранный из конфига пользователя',
      () async {
        final tun = buildTunConfig(jsonEncode(configWith({})));
        final result = await testConfig(tunConfigForTest(tun));

        expect(result.exitCode, 0, reason: output(result));
      },
      skip: ready ? false : reason,
    );

    test(
      'конфиг из ссылок с балансировщиком: ядро берёт узлы из балансировщика',
      () async {
        final json = buildConfigFromLinks(
          parseLinks('$firstLink\n$secondLink').links,
          balancers: [
            {
              'tag': 'cvpn-lb',
              'selector': [proxyTag, '$proxyTag-2'],
            },
          ],
        );
        final result = await testConfig(json);

        expect(result.exitCode, 0, reason: output(result));
        expect(
          ((jsonDecode(json)['routing'] as Map)['rules'] as List).last,
          containsPair('balancerTag', 'cvpn-lb'),
        );
      },
      skip: ready ? false : reason,
    );

    test(
      'туннельный конфиг из ссылок с балансировщиком проходит проверку',
      () async {
        final links = buildConfigFromLinks(
          parseLinks(firstLink).links,
          balancers: [
            {
              'tag': 'cvpn-lb',
              'selector': [proxyTag],
            },
          ],
        );
        final result = await testConfig(
          tunConfigForTest(buildTunConfig(links)),
        );

        expect(result.exitCode, 0, reason: output(result));
      },
      skip: ready ? false : reason,
    );

    test(
      'geo-правило работает, потому что базы лежат рядом с ядром',
      () async {
        final config = configWith({});
        (config['routing'] as Map)['rules'] = [
          {
            'type': 'field',
            'domain': ['geosite:yandex'],
            'outboundTag': 'cvpn-direct',
          },
          {
            'type': 'field',
            'network': 'tcp,udp',
            'outboundTag': 'proxy-a',
          },
        ];
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, 0, reason: output(result));
      },
      skip: ready ? false : reason,
    );
  });

  group('ядро отклоняет конфиг до запуска', () {
    test(
      'balancerTag без объявленного балансировщика',
      () async {
        final config = configWith({});
        (config['routing'] as Map).remove('balancers');
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, isNonZero);
        expect(output(result), contains('balancer lb not found'));
      },
      skip: ready ? false : reason,
    );

    test(
      'балансировщик, объявленный верхним уровнем, ядром не читается',
      () async {
        final config = configWith({});
        (config['routing'] as Map).remove('balancers');
        config['balancers'] = [
          {
            'tag': 'lb',
            'selector': ['proxy-a', 'proxy-b'],
          },
        ];
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, isNonZero);
        expect(output(result), contains('balancer lb not found'));
      },
      skip: ready ? false : reason,
    );

    test(
      'код RU в geosite.dat баз 26.3.27 отсутствует',
      () async {
        final config = configWith({});
        (config['routing'] as Map)['rules'] = [
          {
            'type': 'field',
            'domain': ['geosite:ru'],
            'outboundTag': 'cvpn-direct',
          },
        ];
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, isNonZero);
        expect(output(result), contains('code not found in geosite.dat: RU'));
      },
      skip: ready ? false : reason,
    );

    test(
      'без geo-баз правило geoip:ru не проходит проверку',
      () async {
        // Тот же бинарник, но каталог ассетов пустой: ядро ищет базы по
        // XRAY_LOCATION_ASSET, и именно так проявляется незакрытый ТД-7.
        final empty =
            await Directory.systemTemp.createTemp('cvpn-kernel-nogeo');
        final dir = await Directory.systemTemp.createTemp('cvpn-kernel-cfg');
        final file = File(p.join(dir.path, 'config.json'))
          ..writeAsStringSync(jsonEncode(configWith({})), flush: true);
        try {
          final result = await Process.run(
            xray.absolute.path,
            ['run', '-test', '-config', file.path],
            workingDirectory: p.dirname(xray.absolute.path),
            environment: {'XRAY_LOCATION_ASSET': empty.absolute.path},
          );
          expect(result.exitCode, isNonZero);
          expect(output(result), contains('geoip.dat'));
        } finally {
          await dir.delete(recursive: true);
          await empty.delete(recursive: true);
        }
      },
      skip: ready ? false : reason,
    );

    test(
      'стратегия leastPing без наблюдателя не проходит',
      () async {
        final config = configWith(
          {},
          balancer: {
            'tag': 'lb',
            'selector': ['proxy-a', 'proxy-b'],
            'strategy': {'type': 'leastPing'},
          },
        );
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, isNonZero);
        expect(output(result), contains('not all dependencies are resolved'));
      },
      skip: ready ? false : reason,
    );

    test(
      'запасной outbound без наблюдателя не проходит',
      () async {
        final config = configWith(
          {},
          balancer: {
            'tag': 'lb',
            'selector': ['proxy-a', 'proxy-b'],
            'fallbackTag': 'cvpn-direct',
          },
        );
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, isNonZero);
        expect(output(result), contains('not all dependencies are resolved'));
      },
      skip: ready ? false : reason,
    );

    test(
      'стратегия строкой вместо объекта не разбирается',
      () async {
        final config = configWith(
          {},
          balancer: {
            'tag': 'lb',
            'selector': ['proxy-a', 'proxy-b'],
            'strategy': 'roundRobin',
          },
        );
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, isNonZero);
        expect(output(result), contains('cannot unmarshal string'));
      },
      skip: ready ? false : reason,
    );

    test(
      'правило по протоколу без снифинга конфиг не ломает',
      () async {
        // Ядро собирает такое правило и не ругается — но без снифинга на
        // inbound оно до цели не доходит. Поэтому tun-вход клиента всегда со
        // снифингом, и он переносится в проверочный конфиг.
        final config = configWith({});
        (config['routing'] as Map)['rules'] = [
          {
            'type': 'field',
            'protocol': ['http'],
            'outboundTag': 'cvpn-direct',
          },
          {
            'type': 'field',
            'network': 'tcp,udp',
            'outboundTag': 'proxy-a',
          },
        ];
        final result = await testConfig(jsonEncode(config));

        expect(result.exitCode, 0, reason: output(result));
      },
      skip: ready ? false : reason,
    );
  });
}
