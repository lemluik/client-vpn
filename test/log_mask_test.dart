import 'package:client_vpn/log_mask.dart';
import 'package:flutter_test/flutter_test.dart';

const link = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@203.0.113.7:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp#%D0%A3%D0%B7%D0%B5%D0%BB%201';

void main() {
  group('maskSecrets', () {
    test('ссылка профиля уходит целиком', () {
      final masked = maskSecrets('Добавлен профиль $link');

      expect(masked, contains(maskedLink));
      expect(masked, isNot(contains('example')));
      expect(masked, isNot(contains('203.0.113.7')));
      expect(masked, isNot(contains('2f6bd5a1')));
      expect(masked, contains('Добавлен профиль'));
    });

    test('идентификатор пользователя маскируется', () {
      final masked = maskSecrets('id=2f6bd5a1-1e73-4b1a-9d3c-000000000001');

      expect(masked, 'id=$maskedId');
    });

    test('внешний адрес маскируется, обратный остаётся', () {
      expect(maskSecrets('узел 203.0.113.7:443'), 'узел $maskedAddress:443');
      expect(
        maskSecrets('системный прокси: socks 127.0.0.1:10809'),
        'системный прокси: socks 127.0.0.1:10809',
      );
    });

    test('долгий ключ маскируется', () {
      final masked = maskSecrets(
        'pbk SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234 sid ab12cd34',
      );

      expect(masked, contains(maskedKey));
      expect(masked, isNot(contains('SaMdKey')));
      expect(masked, contains('ab12cd34'));
    });

    test('адрес шестой версии маскируется, отметка времени остаётся', () {
      expect(maskSecrets('узел 2001:db8::7'), 'узел $maskedAddress');
      expect(maskSecrets('::1'), '::1');
      expect(
        maskSecrets('2026/10/13 12:30:45 [Warning] запуск'),
        '2026/10/13 12:30:45 [Warning] запуск',
      );
    });

    test('версия ядра и служебные отметки остаются', () {
      const line = '[ERR] Xray 26.3.27 остановлен (код: 0)';
      expect(maskSecrets(line), line);
    });

    test('журнал целиком маскируется построчно', () {
      final text = maskLog([
        'Добавлен профиль $link',
        'Системный прокси: http 127.0.0.1:10808',
      ]);
      final lines = text.split('\n');

      expect(lines, hasLength(2));
      expect(lines.first, contains(maskedLink));
      expect(lines.last, 'Системный прокси: http 127.0.0.1:10808');
    });
  });
}
