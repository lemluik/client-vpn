import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/failover.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/provider.dart';
import 'package:client_vpn/share_link.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const linkOne =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

const linkTwo =
    'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:8443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%202';

const plainBody = '$linkOne\n$linkTwo';

const subscriptionUrl = 'https://example.org/sub';

/// «Провайдер Тест» в base64 — в таком виде заголовок присылают панели.
const titleBase64 = '0J/RgNC+0LLQsNC50LTQtdGAINCi0LXRgdGC';

const fullHeaders = {
  'profile-title': titleBase64,
  'profile-update-interval': '12',
  'support-url': 'https://example.com/help',
  'subscription-userinfo': 'upload=0; download=1024; total=4096; expire=0',
};

final fixedNow = DateTime.utc(2026, 10, 13, 12);

SubscriptionFetcher responds({
  String body = plainBody,
  Map<String, String> headers = const {},
}) =>
    (url) async => SubscriptionResponse(body: body, headers: headers);

SubscriptionFetcher failsWith(Object error) =>
    (url) async => throw error;

String base64Body(String text) => base64.encode(utf8.encode(text));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('профили из ссылок', () {
    test('ссылки становятся профилем и активным подключением', () async {
      final store = await ProfileStore.open();
      final profile = await store.addLinks(
        name: '',
        links: parseLinks(plainBody).links,
        now: fixedNow,
      );

      expect(store.profiles, hasLength(1));
      expect(profile.name, 'Узел 1');
      expect(profile.kind, ProfileKind.links);
      expect(profile.canStart, isTrue);
      expect(store.active?.id, profile.id);
    });

    test('сохранённое переживает перезапуск приложения', () async {
      final store = await ProfileStore.open();
      final profile = await store.addLinks(
        name: 'Мой профиль',
        links: parseLinks(plainBody).links,
        now: fixedNow,
      );

      final reopened = await ProfileStore.open();

      expect(reopened.profiles, hasLength(1));
      expect(reopened.profiles.single.id, profile.id);
      expect(reopened.profiles.single.name, 'Мой профиль');
      expect(reopened.profiles.single.links, hasLength(2));
      expect(reopened.profiles.single.links.last.port, 8443);
      expect(reopened.active?.id, profile.id);
    });

    test('повторное добавление тех же ссылок не плодит профиль', () async {
      final store = await ProfileStore.open();
      final links = parseLinks(plainBody).links;
      await store.addLinks(name: 'Первый', links: links, now: fixedNow);
      await store.addLinks(name: 'Второй', links: links, now: fixedNow);

      expect(store.profiles, hasLength(1));
      expect(store.profiles.single.name, 'Второй');
    });

    test('переименование и смена активного профиля', () async {
      final store = await ProfileStore.open();
      final first = await store.addLinks(
        name: 'Первый',
        links: parseLinks(linkOne).links,
        now: fixedNow,
      );
      final second = await store.addLinks(
        name: 'Второй',
        links: parseLinks(linkTwo).links,
        now: fixedNow,
      );

      await store.rename(first.id, 'Переименован');
      expect(store.profiles.first.name, 'Переименован');

      await store.setActive(second.id);
      expect(store.active?.id, second.id);

      expect(
        () => store.setActive('нет такого'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('файл пользователя', () {
    test('файл остаётся файлом и отдаётся ядру как есть', () async {
      final store = await ProfileStore.open();
      await store.addFile(
        const VpnConfig(
          name: 'config.json',
          json: '{"log":{"loglevel":"none"}}',
          path: 'D:/configs/config.json',
        ),
        now: fixedNow,
      );

      final config = store.activeConfig();
      expect(config.name, 'config.json');
      expect(config.json, '{"log":{"loglevel":"none"}}');
      expect(config.path, 'D:/configs/config.json');
    });

    test('пустое содержимое файла не даёт стартовать', () async {
      final store = await ProfileStore.open();
      await store.addFile(const VpnConfig(name: 'пусто.json', json: ''));

      expect(store.active!.canStart, isFalse);
      expect(
        store.activeConfig,
        throwsA(
          isA<LinkFormatException>().having(
            (error) => error.message,
            'message',
            contains('недоступен'),
          ),
        ),
      );
    });
  });

  group('конфиг ядра из ссылок', () {
    test('собирается в памяти без файла на диске', () async {
      final store = await ProfileStore.open();
      await store.addLinks(
        name: 'Подписка',
        links: parseLinks(plainBody).links,
        now: fixedNow,
      );

      final config = store.activeConfig();
      expect(config.path, isNull);

      final document = jsonDecode(config.json) as Map<String, dynamic>;
      final inbounds = document['inbounds'] as List;
      final outbounds = document['outbounds'] as List;
      final routing = document['routing'] as Map<String, dynamic>;
      final rules = routing['rules'] as List;

      expect(inbounds, hasLength(2));
      expect(outbounds, hasLength(3));
      expect(outbounds.last['protocol'], 'freedom');
      expect(routing['domainStrategy'], 'AsIs');
      // Автопереключение внутри региона (МК-3, МК-6): узлов два, поэтому
      // завершающее правило ведёт на балансировщик, а наблюдатель мерит
      // задержки узлов — без списка субъектов он не делает ни одной пробы.
      expect(routing['balancers'], hasLength(1));
      expect(((routing['balancers'] as List).first as Map)['selector'], [
        'cvpn-proxy',
        'cvpn-proxy-2',
      ]);
      expect(document['observatory'], {
        'subjectSelector': ['cvpn-proxy', 'cvpn-proxy-2'],
        'probeURL': defaultProbeEndpoint,
        'probeInterval': regionProbeInterval,
        'enableConcurrency': true,
      });
      expect(
        (rules.last as Map<String, dynamic>)['balancerTag'],
        regionBalancerTag,
      );
    });

    test('без активного профиля ошибка понятна пользователю', () async {
      final store = await ProfileStore.open();
      expect(store.isEmpty, isTrue);
      expect(
        store.activeConfig,
        throwsA(
          isA<LinkFormatException>().having(
            (error) => error.message,
            'message',
            'Сначала добавьте подключение',
          ),
        ),
      );
    });
  });

  group('подписка провайдера', () {
    test('добавляется вместе с кэшем и заголовками', () async {
      final store = await ProfileStore.open();
      final added = await store.addSubscription(
        subscriptionUrl,
        fetch: responds(body: base64Body(plainBody), headers: fullHeaders),
        now: fixedNow,
      );

      expect(added.ok, isTrue);
      expect(added.profile?.kind, ProfileKind.subscription);
      expect(added.profile?.name, 'Провайдер Тест');
      expect(store.providers, hasLength(1));
      expect(store.providers.single.updateIntervalHours, 12);
      expect(store.providers.single.supportUrl, 'https://example.com/help');
      expect(store.providers.single.usage?.remaining, 3072);
      expect(store.providers.single.links, hasLength(2));
      expect(store.active?.id, added.profile?.id);
    });

    test('старт по кэшу без сети после перезапуска', () async {
      final store = await ProfileStore.open();
      await store.addSubscription(
        subscriptionUrl,
        fetch: responds(headers: fullHeaders),
        now: fixedNow,
      );

      final reopened = await ProfileStore.open();
      final document =
          jsonDecode(reopened.activeConfig().json) as Map<String, dynamic>;

      expect(reopened.providers.single.links, hasLength(2));
      expect(document['outbounds'] as List, hasLength(3));
    });

    test('сбой получения не создаёт пустой профиль', () async {
      final store = await ProfileStore.open();
      final added = await store.addSubscription(
        subscriptionUrl,
        fetch: failsWith(const SocketException('нет связи')),
        now: fixedNow,
      );

      expect(added.ok, isFalse);
      expect(added.error, 'Нет связи с провайдером');
      expect(store.profiles, isEmpty);
      expect(store.providers, hasLength(1));
    });

    test('сбой обновления оставляет прежний кэш рабочим', () async {
      final store = await ProfileStore.open();
      final added = await store.addSubscription(
        subscriptionUrl,
        fetch: responds(headers: fullHeaders),
        now: fixedNow,
      );

      final result = await store.refresh(
        added.provider.id,
        fetch: failsWith(TimeoutException('долго')),
        now: fixedNow.add(const Duration(days: 2)),
      );

      expect(result.ok, isFalse);
      expect(result.provider.lastUpdated, fixedNow);
      expect(result.provider.lastError, 'Провайдер не ответил вовремя');

      final reopened = await ProfileStore.open();
      expect(reopened.providers.single.links, hasLength(2));
      expect(reopened.profiles.single.links, hasLength(2));
      expect(reopened.activeConfig().json, contains('cvpn-proxy'));
    });

    test('повторное добавление того же адреса обновляет профиль', () async {
      final store = await ProfileStore.open();
      await store.addSubscription(
        subscriptionUrl,
        fetch: responds(body: linkOne),
        now: fixedNow,
      );
      expect(store.profiles.single.links, hasLength(1));

      final again = await store.addSubscription(
        '  $subscriptionUrl  ',
        fetch: responds(body: plainBody),
        now: fixedNow.add(const Duration(hours: 1)),
      );

      expect(store.providers, hasLength(1));
      expect(store.profiles, hasLength(1));
      expect(again.profile?.links, hasLength(2));
    });

    test('автообновление срабатывает только по интервалу', () async {
      final store = await ProfileStore.open();
      await store.addSubscription(
        subscriptionUrl,
        fetch: responds(headers: fullHeaders),
        now: fixedNow,
      );

      var calls = 0;
      Future<SubscriptionResponse> counted(String url) async {
        calls++;
        return const SubscriptionResponse(body: plainBody);
      }

      expect(
        store.dueForUpdate(fixedNow.add(const Duration(hours: 11))),
        isEmpty,
      );
      final early = await store.refreshDue(
        fetch: counted,
        now: fixedNow.add(const Duration(hours: 11)),
      );
      expect(early, isEmpty);
      expect(calls, 0);

      final dueAt = fixedNow.add(const Duration(hours: 13));
      expect(store.dueForUpdate(dueAt), hasLength(1));
      final late = await store.refreshDue(fetch: counted, now: dueAt);
      expect(late, hasLength(1));
      expect(late.single.ok, isTrue);
      expect(calls, 1);
      expect(store.providers.single.lastUpdated, dueAt);
    });

    test('удаление профиля убирает одинокого провайдера', () async {
      final store = await ProfileStore.open();
      final added = await store.addSubscription(
        subscriptionUrl,
        fetch: responds(headers: fullHeaders),
        now: fixedNow,
      );

      expect(await store.remove(added.profile!.id), isTrue);
      expect(store.profiles, isEmpty);
      expect(store.providers, isEmpty);
      expect(store.active, isNull);
      expect(await store.remove('нет такого'), isFalse);
    });
  });

  group('устойчивость хранилища', () {
    test('битые записи пропускаются, остальные остаются', () async {
      SharedPreferences.setMockInitialValues({
        'profiles.v1':
            '[{"id":"хороший","name":"Целый","kind":"links",'
            '"added":"2026-10-13T12:00:00.000Z","links":["$linkOne"]},'
            '{"name":"без идентификатора"}]',
        'providers.v1': 'это не список',
        'active_profile.v1': 'нет такого',
      });

      final store = await ProfileStore.open();

      expect(store.profiles, hasLength(1));
      expect(store.profiles.single.name, 'Целый');
      expect(store.profiles.single.links, hasLength(1));
      expect(store.providers, isEmpty);
      expect(store.active, isNull);
    });

    test('нечитаемое содержимое ключа не мешает открытию', () async {
      SharedPreferences.setMockInitialValues({
        'profiles.v1': '{{{',
        'providers.v1': '[{"id":123}]',
      });

      final store = await ProfileStore.open();

      expect(store.profiles, isEmpty);
      expect(store.providers, isEmpty);
    });
  });
}
