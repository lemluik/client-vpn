import 'dart:async';
import 'dart:io';

import 'package:client_vpn/provider.dart';
import 'package:client_vpn/subscription.dart';
import 'package:flutter_test/flutter_test.dart';

const linkOne = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

const linkTwo = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:8443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%202';

const plainBody = '$linkOne\n$linkTwo';

/// «Провайдер Тест» в base64 — так заголовок присылают большинство панелей.
const titleBase64 = '0J/RgNC+0LLQsNC50LTQtdGAINCi0LXRgdGC';

const fullHeaders = {
  'profile-title': titleBase64,
  'profile-update-interval': '12',
  'support-url': 'https://example.com/help',
  'subscription-userinfo':
      'upload=0; download=1024; total=4096; expire=1893456000',
};

final fixedNow = DateTime.utc(2026, 10, 13, 12);

Provider sampleProvider({
  String? cachedBody,
  DateTime? lastUpdated,
  String? lastError,
}) =>
    Provider(
      id: providerIdOf('https://example.org/sub'),
      url: 'https://example.org/sub',
      name: 'Прежнее имя',
      cachedBody: cachedBody,
      lastUpdated: lastUpdated,
      lastError: lastError,
    );

SubscriptionFetcher responds({
  String body = plainBody,
  Map<String, String> headers = const {},
}) =>
    (url) async => SubscriptionResponse(body: body, headers: headers);

SubscriptionFetcher failsWith(Object error) => (url) async => throw error;

void main() {
  group('providerIdOf', () {
    test('один адрес даёт один идентификатор', () {
      expect(
        providerIdOf('https://example.org/sub'),
        providerIdOf('  https://example.org/sub  '),
      );
      expect(
        providerIdOf('https://example.org/sub'),
        isNot(providerIdOf('https://example.org/other')),
      );
    });
  });

  group('Provider.needsUpdate', () {
    test('без отметки об обновлении обновляться пора', () {
      expect(sampleProvider().needsUpdate(fixedNow), isTrue);
    });

    test('внутри интервала обновление не требуется', () {
      final provider = sampleProvider(
        lastUpdated: fixedNow.subtract(const Duration(hours: 11)),
      );
      expect(provider.updateIntervalHours, defaultUpdateIntervalHours);
      expect(provider.needsUpdate(fixedNow), isFalse);

      final short = Provider(
        id: provider.id,
        url: provider.url,
        updateIntervalHours: 12,
        lastUpdated: fixedNow.subtract(const Duration(hours: 11)),
      );
      expect(short.needsUpdate(fixedNow), isFalse);
      expect(
        short.needsUpdate(fixedNow.add(const Duration(hours: 2))),
        isTrue,
      );
    });
  });

  group('Provider.accessEnded', () {
    test('срок из заголовка провайдера виден клиенту', () {
      final past = Provider(
        id: 'a',
        url: 'https://example.org/sub',
        usage: SubscriptionUsage.parse(
          'upload=0; download=0; total=0; expire=1000',
        ),
      );
      expect(past.accessEnded(fixedNow), isTrue);
      expect(sampleProvider().accessEnded(fixedNow), isFalse);
    });
  });

  group('Provider serialization', () {
    test('кэш, интервал и остаток трафика переживают сохранение', () {
      final provider = sampleProvider(
        cachedBody: plainBody,
        lastUpdated: fixedNow,
      ).copyWith(
        name: 'Провайдер Тест',
        updateIntervalHours: 6,
        supportUrl: 'https://example.com/help',
        usage: const SubscriptionUsage(
          upload: 0,
          download: 1024,
          total: 4096,
          expire: null,
        ),
      );

      final restored = Provider.fromJson(provider.toJson());

      expect(restored.id, provider.id);
      expect(restored.name, 'Провайдер Тест');
      expect(restored.updateIntervalHours, 6);
      expect(restored.supportUrl, 'https://example.com/help');
      expect(restored.lastUpdated, fixedNow);
      expect(restored.usage?.remaining, 3072);
      expect(restored.links, hasLength(2));
      expect(restored.links.first.name, 'Узел 1');
    });

    test('запись без адреса отклоняется', () {
      expect(
        () => Provider.fromJson({'id': 'a', 'name': 'без адреса'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('нечитаемый интервал заменяется значением по умолчанию', () {
      final restored = Provider.fromJson({
        'id': 'a',
        'url': 'https://example.org/sub',
        'interval': -3,
      });
      expect(restored.updateIntervalHours, defaultUpdateIntervalHours);
    });
  });

  group('refreshProvider', () {
    test('успех: имя, интервал, поддержка и остаток трафика', () async {
      final result = await refreshProvider(
        sampleProvider(lastError: 'Прежний сбой'),
        fetch: responds(body: plainBody, headers: fullHeaders),
        now: fixedNow,
      );

      expect(result.ok, isTrue);
      expect(result.provider.name, 'Провайдер Тест');
      expect(result.provider.updateIntervalHours, 12);
      expect(result.provider.supportUrl, 'https://example.com/help');
      expect(result.provider.usage?.remaining, 3072);
      expect(result.provider.lastUpdated, fixedNow);
      expect(result.provider.lastError, isNull);
      expect(result.provider.links, hasLength(2));
    });

    test('заголовок без base64 тоже принимается', () async {
      final result = await refreshProvider(
        sampleProvider(),
        fetch: responds(headers: {'Profile-Title': 'Обычное имя'}),
        now: fixedNow,
      );

      expect(result.provider.name, 'Обычное имя');
      expect(result.provider.updateIntervalHours, defaultUpdateIntervalHours);
    });

    test('пустой ответ провайдера не затирает кэш', () async {
      final result = await refreshProvider(
        sampleProvider(cachedBody: plainBody, lastUpdated: fixedNow),
        fetch: responds(body: 'пусто'),
        now: fixedNow.add(const Duration(days: 2)),
      );

      expect(result.ok, isFalse);
      expect(result.error, 'В ответе провайдера нет ни одного профиля');
      expect(result.provider.links, hasLength(2));
      expect(result.provider.lastUpdated, fixedNow);
      expect(result.provider.lastError, result.error);
    });

    test('сбой сети оставляет пользователя на кэше', () async {
      final result = await refreshProvider(
        sampleProvider(cachedBody: plainBody, lastUpdated: fixedNow),
        fetch: failsWith(const SocketException('нет связи')),
        now: fixedNow.add(const Duration(days: 2)),
      );

      expect(result.ok, isFalse);
      expect(result.error, 'Нет связи с провайдером');
      expect(result.provider.links, hasLength(2));
      expect(result.provider.lastUpdated, fixedNow);
      expect(result.error, isNot(contains('нет связи')));
    });

    test('ожидание дольше предела даёт понятный текст', () async {
      final result = await refreshProvider(
        sampleProvider(),
        fetch: failsWith(TimeoutException('долго')),
        now: fixedNow,
      );
      expect(result.error, 'Провайдер не ответил вовремя');
    });

    test('текст ошибки не содержит адрес провайдера', () async {
      final result = await refreshProvider(
        sampleProvider(),
        fetch: failsWith(const HttpException('сбой 500')),
        now: fixedNow,
      );
      expect(result.error, isNot(contains('example.org')));
      expect(result.error, isNot(contains('500')));
    });
  });

  group('fetchSubscription', () {
    test('адрес не подписки отклоняется до выхода в сеть', () async {
      for (final bad in ['ftp://example.org/sub', linkOne, 'не адрес', '']) {
        await expectLater(
          fetchSubscription(bad),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('http'),
            ),
          ),
        );
      }
    });
  });
}
