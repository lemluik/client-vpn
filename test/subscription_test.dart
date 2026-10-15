import 'dart:convert';

import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/subscription.dart';
import 'package:flutter_test/flutter_test.dart';

const firstLink = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?security=reality&sni=www.example.org&fp=chrome'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMdKeySaMd1234&sid=a1b2c3d4'
    '#%D0%9F%D0%B5%D1%80%D0%B2%D1%8B%D0%B9';

const secondLink = 'trojan://pass@example.org:8443?sni=example.org#Second';

String encoded(String text) => base64.encode(utf8.encode(text));

void main() {
  group('parseSubscription: тело', () {
    test('распознаёт открытый список ссылок', () {
      final subscription = parseSubscription('$firstLink\n$secondLink');

      expect(subscription.links, hasLength(2));
      expect(subscription.skipped, isEmpty);
      expect(subscription.links.first.name, 'Первый');
      expect(subscription.links.last.protocol, LinkProtocol.trojan);
    });

    test('распознаёт подписку в base64', () {
      final subscription =
          parseSubscription(encoded('$firstLink\n$secondLink'));

      expect(subscription.links, hasLength(2));
      expect(subscription.links.first.source, firstLink);
    });

    test('принимает base64url без знаков равенства', () {
      final urlSafe = encoded('$firstLink\n$secondLink')
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll('=', '');

      expect(parseSubscription(urlSafe).links, hasLength(2));
    });

    test('одиночная ссылка тоже принимается за подписку', () {
      expect(parseSubscription(firstLink).links, hasLength(1));
    });

    test('пустое тело не рвёт разбор', () {
      final subscription = parseSubscription('   ');

      expect(subscription.links, isEmpty);
      expect(subscription.skipped, isEmpty);
      expect(subscription.isEmpty, isTrue);
    });

    test('чужие профили пропускаются, наши принимаются', () {
      final subscription =
          parseSubscription(encoded('$firstLink\nss://YWVz@example.org:8389'));

      expect(subscription.links, hasLength(1));
      expect(subscription.skipped, hasLength(1));
      expect(subscription.skipped.single.scheme, 'ss');
    });

    test('бинарный мусор не принимается за подписку', () {
      final garbage = base64.encode([0xC3, 0x28, 0xFF, 0xFE]);

      final subscription = parseSubscription(garbage);

      expect(subscription.links, isEmpty);
      expect(subscription.skipped, hasLength(1));
      expect(subscription.skipped.single.scheme, 'неизвестно');
    });
  });

  group('parseSubscription: заголовки профиля', () {
    test('читает имя, интервал, остаток и поддержку', () {
      final subscription = parseSubscription(
        encoded('$firstLink\n$secondLink'),
        headers: const {
          'profile-title': 'UHJvdmlkZXIgVGVzdA==',
          'profile-update-interval': '12',
          'subscription-userinfo':
              'upload=100; download=200; total=1000; expire=0',
          'support-url': 'https://example.org/support',
        },
      );

      expect(subscription.title, 'Provider Test');
      expect(subscription.updateInterval, const Duration(hours: 12));
      expect(subscription.supportUrl, 'https://example.org/support');
      expect(subscription.usage?.upload, 100);
      expect(subscription.usage?.download, 200);
      expect(subscription.usage?.total, 1000);
      expect(subscription.usage?.remaining, 700);
      expect(subscription.usage?.expire, isNull);
    });

    test('узел и комната чата читаются из заголовков', () {
      final subscription = parseSubscription(
        firstLink,
        headers: const {
          'CHAT-HOMESERVER': 'https://chat.example:8448',
          'chat-room': '  !abc:chat.example  ',
        },
      );

      expect(subscription.chatHomeserver, 'https://chat.example:8448');
      expect(subscription.chatRoomId, '!abc:chat.example');
    });

    test('без заголовков чата подписка остаётся рабочей', () {
      final subscription = parseSubscription(firstLink);

      expect(subscription.links, hasLength(1));
      expect(subscription.chatHomeserver, isNull);
      expect(subscription.chatRoomId, isNull);
    });

    test('пустой заголовок чата не превращается в адрес', () {
      final subscription = parseSubscription(
        firstLink,
        headers: const {'chat-homeserver': '   '},
      );

      expect(subscription.chatHomeserver, isNull);
    });

    test('имя подписки принимается и в открытом виде', () {
      final subscription = parseSubscription(
        firstLink,
        headers: const {'profile-title': 'Открытое имя'},
      );

      expect(subscription.title, 'Открытое имя');
    });

    test('регистр и пробелы в именах заголовков не важны', () {
      final subscription = parseSubscription(
        firstLink,
        headers: const {' Profile-Title ': 'RGVtbw=='},
      );

      expect(subscription.title, 'Demo');
    });

    test('нулевой и мусорный интервал не принимаются', () {
      expect(
        parseSubscription(
          firstLink,
          headers: const {'profile-update-interval': '0'},
        ).updateInterval,
        isNull,
      );
      expect(
        parseSubscription(
          firstLink,
          headers: const {'profile-update-interval': 'час'},
        ).updateInterval,
        isNull,
      );
    });

    test('отрицательный остаток трафика обрезается до нуля', () {
      final usage =
          SubscriptionUsage.parse('upload=900; download=900; total=1000');

      expect(usage?.remaining, 0);
    });

    test('без предела трафика остаток неизвестен', () {
      expect(
        SubscriptionUsage.parse('upload=1; download=2')?.remaining,
        isNull,
      );
      expect(SubscriptionUsage.parse(''), isNull);
      expect(SubscriptionUsage.parse(null), isNull);
      expect(SubscriptionUsage.parse('мусор'), isNull);
    });

    test('срок доступа сравнивается с переданным моментом', () {
      final usage = SubscriptionUsage.parse('expire=1700000000');
      final expiry = DateTime.fromMillisecondsSinceEpoch(
        1700000000 * 1000,
        isUtc: true,
      );

      expect(usage?.expire, expiry);
      expect(usage!.expiredAt(expiry), isTrue);
      expect(
        usage.expiredAt(expiry.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(
        usage.expiredAt(expiry.add(const Duration(seconds: 1))),
        isTrue,
      );
    });
  });

  group('encodeSubscription', () {
    test('экспорт возвращается тем же разбором без потерь', () {
      final links = parseSubscription('$firstLink\n$secondLink').links;

      final restored = parseSubscription(encodeSubscription(links));

      expect(restored.links, hasLength(2));
      expect(
        restored.links.map((link) => link.source),
        [firstLink, secondLink],
      );
    });

    test('без обёртки экспорт остаётся открытым списком', () {
      final links = parseSubscription('$firstLink\n$secondLink').links;

      final text = encodeSubscription(links, asBase64: false);

      expect(text, '$firstLink\n$secondLink');
      expect(parseSubscription(text).links, hasLength(2));
    });

    test('пустой список экспортируется пустой строкой', () {
      expect(encodeSubscription(const []), encoded(''));
      expect(encodeSubscription(const [], asBase64: false), '');
    });
  });
}
