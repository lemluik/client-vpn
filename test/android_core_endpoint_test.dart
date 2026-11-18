import 'dart:convert';

import 'package:client_vpn/android_core.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Конфиг с [proxies] прокси-выходами и завершающим freedom.
/// Адреса тестовые, ключи не боевые.
String _config(int proxies) => jsonEncode({
  'outbounds': [
    for (var i = 0; i < proxies; i++)
      {
        'protocol': 'vless',
        'tag': 'proxy-$i',
        'settings': {
          'vnext': [
            {'address': 'entry$i.example.test', 'port': 443},
          ],
        },
      },
    {'protocol': 'freedom', 'tag': 'direct'},
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('client_vpn/tunnel');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('один выход: строка статуса называет его адрес', () async {
    final core = AndroidCore();
    addTearDown(core.dispose);

    await core.validate(VpnConfig(name: 'test.json', json: _config(1)));

    expect(core.endpointLabel, 'entry0.example.test:443');
    expect(calls.single.method, 'validate');
  });

  test('несколько выходов: адрес первого не подставляется (Д-202610-22)',
      () async {
    final core = AndroidCore();
    addTearDown(core.dispose);

    await core.validate(VpnConfig(name: 'test.json', json: _config(2)));

    // Балансировщик выбирает маршрут сам: достоверного адреса нет.
    expect(core.endpointLabel, isNull);
  });

  test('выход без адреса сервера: назван протокол, не выдуманный адрес',
      () async {
    final core = AndroidCore();
    addTearDown(core.dispose);
    final json = jsonEncode({
      'outbounds': [
        {'protocol': 'socks', 'tag': 'proxy-0', 'settings': {}},
        {'protocol': 'freedom', 'tag': 'direct'},
      ],
    });

    await core.validate(VpnConfig(name: 'test.json', json: json));

    expect(core.endpointLabel, 'socks');
  });
}