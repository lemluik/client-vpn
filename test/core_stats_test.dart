import 'dart:convert';

import 'package:client_vpn/core_stats.dart';
import 'package:client_vpn/traffic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('injectStatsApi', () {
    const userJson = '''
{
  "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks"}],
  "outbounds": [{"protocol": "freedom"}],
  "policy": {"levels": {"0": {"handshake": 4}}}
}
''';

    test('добавляет api, stats и учёт байтов, не ломая policy', () {
      final injected = jsonDecode(CoreStats.injectStatsApi(userJson, 12345));

      expect(injected['api'], {
        'tag': 'api',
        'services': ['StatsService'],
        'listen': '127.0.0.1:12345',
      });
      expect(injected['stats'], {});
      // Существующая политика пользователя сохраняется.
      expect(injected['policy']['levels']['0']['handshake'], 4);
      expect(injected['policy']['system']['statsInboundUplink'], true);
      expect(injected['policy']['system']['statsInboundDownlink'], true);
      // Inbound с protocol `api` ядро 26.3.27 отвергает — его быть не должно.
      expect(injected['inbounds'], hasLength(1));
    });

    test('конфиг не JSON-объект — FormatException', () {
      expect(
        () => CoreStats.injectStatsApi('[]', 1),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('formatBytes', () {
    test('единицы Б/КБ/МБ/ГБ, один знак', () {
      expect(formatBytes(0), '0 Б');
      expect(formatBytes(1023), '1023 Б');
      expect(formatBytes(1536), '1.5 КБ');
      expect(formatBytes(1024 * 1024), '1.0 МБ');
      expect(formatBytes(2.5 * 1024 * 1024 * 1024), '2.5 ГБ');
    });

    test('скорость — те же единицы', () {
      expect(formatBytes(123.4), '123 Б');
      expect(formatBytes(2048.0), '2.0 КБ');
    });
  });
}
