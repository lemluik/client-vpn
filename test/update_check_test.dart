import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/app_metadata.dart';
import 'package:client_vpn/services/service_config.dart';
import 'package:client_vpn/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Установленная сборка для проверок: закрытая 0.4.5, код 3, проектная подпись.
const AppMetadata _installed = AppMetadata(
  versionName: '0.4.5',
  versionCode: 3,
  applicationId: 'com.clientvpn.client_vpn',
  signerSha256:
      'f579799b71032b9b8bde11cb7d81e0eca7af4b01b0a43be674c319baffb7be4b',
);

/// Кормит манифест с петлевого адреса: `AppProxy` для петлевой цели всегда
/// отдаёт `DIRECT`, поэтому проверка идёт через настоящий стек `HttpClient`,
/// а не через подставной клиент.
Future<({String url, Future<void> Function() stop})> _feed(
  List<int> body, {
  int status = 200,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..add(body);
    await request.response.close();
  });
  return (
    url: 'http://127.0.0.1:${server.port}/manifest',
    stop: () => server.close(force: true),
  );
}

Future<({String url, Future<void> Function() stop})> _jsonFeed(
  Object? value, {
  int status = 200,
}) =>
    _feed(utf8.encode(jsonEncode(value)), status: status);

void main() {
  test('версия приводится к числовым разрядам', () {
    expect(normalizeVersion('v0.4.0+7'), '0.4.0');
    expect(normalizeVersion('release-0.4.0'), '0.4.0');
    expect(normalizeVersion('без цифр'), '');
  });

  test('сравнение версий идёт по разрядам, а не по строке', () {
    expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
    expect(compareVersions('0.3.0', '0.3.0'), 0);
    expect(compareVersions('0.3', '0.3.0'), 0);
    expect(compareVersions('0.2.9', '0.3.0'), lessThan(0));
  });

  test('манифест страницы выпусков GitHub разобран', () {
    final release = parseRelease({
      'tag_name': 'v0.4.0',
      'body': 'Список изменений',
      'assets': [
        {
          'name': 'client-vpn-windows-v0.4.0.zip',
          'browser_download_url': 'https://example.test/win.zip',
        },
        {
          'name': 'client-vpn-android-v0.4.0.apk',
          'browser_download_url': 'https://example.test/android.apk',
        },
        {
          'name': 'SHA256SUMS.txt',
          'browser_download_url': 'https://example.test/sums',
        },
      ],
    });
    expect(release?.version, '0.4.0');
    expect(release?.notes, 'Список изменений');
    expect(release?.downloadUrlFor('windows'), 'https://example.test/win.zip');
    expect(release?.downloadUrlFor('android'), 'https://example.test/android.apk');
  });

  test('собственный манифест и одиночная ссылка разобраны', () {
    final release = parseRelease({
      'version': '0.9.0',
      'notes': 'Второй канал раздачи',
      'files': {'windows': 'https://example.test/a.zip'},
    });
    expect(release?.version, '0.9.0');
    // платформы нет в списке — отдаём единственную имеющуюся ссылку
    expect(release?.downloadUrlFor('android'), 'https://example.test/a.zip');

    final single = parseRelease({'version': '1.0', 'url': 'https://example.test/b'});
    expect(single?.downloadUrlFor('windows'), 'https://example.test/b');
  });

  test('macOS не получает установщик другой платформы', () {
    final release = parseRelease({
      'version': '0.9.0',
      'files': {'windows': 'https://example.test/a.zip'},
    });
    expect(release?.downloadUrlFor('macos', anyAsLast: false), isNull);

    final withMac = parseRelease({
      'version': '0.9.0',
      'files': {
        'windows': 'https://example.test/a.zip',
        'macos': 'https://example.test/m.dmg',
      },
    });
    expect(withMac?.downloadUrlFor('macos', anyAsLast: false), 'https://example.test/m.dmg');
  });

  test('манифест без версии не разбирается', () {
    expect(parseRelease(null), isNull);
    expect(parseRelease([]), isNull);
    expect(parseRelease({'notes': 'только текст'}), isNull);
  });

  test('companion-ассет .sha256 суммой не считается и привязан к пакету', () {
    final release = parseRelease({
      'tag_name': 'v0.4.1',
      'assets': [
        {
          'name': 'neutrino-android-v0.4.1.apk',
          'browser_download_url':
              'https://example.test/files/neutrino-android-v0.4.1.apk',
        },
        {
          'name': 'neutrino-android-v0.4.1.apk.sha256',
          'browser_download_url':
              'https://example.test/files/neutrino-android-v0.4.1.apk.sha256',
        },
      ],
    });
    expect(release?.sha256, isNull);
    expect(
        release?.checksumUrlFor(
            'https://example.test/files/neutrino-android-v0.4.1.apk'),
        'https://example.test/files/neutrino-android-v0.4.1.apk.sha256');
    // сумма привязана к этому пакету, а не к первой ссылке подряд
    expect(release?.checksumUrlFor('https://example.test/other.zip'), isNull);
  });

  test('сумма собственного манифеста прочитана в обоих видах', () {
    final nested = parseRelease({
      'version': '0.5.0',
      'files': {
        'android': {
          'url': 'https://example.test/a.apk',
          'sha256': 'ABCDEF',
        },
      },
    });
    expect(nested?.sha256, 'abcdef');
    expect(nested?.downloadUrlFor('android'), 'https://example.test/a.apk');

    final flat = parseRelease({
      'version': '0.5.0',
      'url': 'https://example.test/a.apk',
      'sha256': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    });
    expect(flat?.sha256, flat?.sha256?.toLowerCase());
    expect(flat?.checksums, isEmpty);
  });

  test('источник с релизом новее текущей версии найден', () async {
    final feed = await _jsonFeed({
      'version': '9.9.9',
      'notes': 'тест',
      'files': {'windows': 'https://example.test/win.zip'},
    });
    addTearDown(feed.stop);
    final result = await checkForUpdate(
      feed: feed.url,
      installed: _installed,
      platform: 'windows',
    );
    expect(result.hasUpdate, isTrue);
    expect(result.release?.version, '9.9.9');
    expect(result.error, isNull);
  });

  test('равная версия обновлением не считается', () async {
    final feed = await _jsonFeed({
      'version': '0.4.5',
      'versionCode': 3,
      'files': {'windows': 'https://example.test/win.zip'},
    });
    addTearDown(feed.stop);
    final result = await checkForUpdate(
      feed: feed.url,
      installed: _installed,
      platform: 'windows',
    );
    expect(result.hasUpdate, isFalse);
    expect(result.error, 'Обновлений нет');
  });

  test('более старая версия не предлагается', () async {
    final feed = await _jsonFeed({
      'version': '0.4.4',
      'versionCode': 2,
      'files': {'windows': 'https://example.test/win.zip'},
    });
    addTearDown(feed.stop);
    final result = await checkForUpdate(
      feed: feed.url,
      installed: _installed,
      platform: 'windows',
    );
    expect(result.hasUpdate, isFalse);
    expect(result.error, contains('понижение версии не предлагается'));
  });

  test('плохой ответ источника превращается в нейтральное сообщение', () async {
    final notFound = await _feed(utf8.encode('{}'), status: 404);
    addTearDown(notFound.stop);
    final code = await checkForUpdate(
      feed: notFound.url,
      installed: _installed,
      platform: 'windows',
    );
    expect(code.error, contains('404'));

    final garbage = await _feed(utf8.encode('не json совсем'));
    addTearDown(garbage.stop);
    final broken = await checkForUpdate(
      feed: garbage.url,
      installed: _installed,
      platform: 'windows',
    );
    expect(broken.error, 'Источник вернул не JSON');

    final big = await _feed(List.filled(maxUpdateResponseBytes + 10, 0x30));
    addTearDown(big.stop);
    final oversize = await checkForUpdate(
      feed: big.url,
      installed: _installed,
      platform: 'windows',
    );
    expect(oversize.error, contains('слишком большой'));
  });

  test('мёртвый источник не выглядит как сбой подключения', () async {
    final feed = await _feed(utf8.encode('{}'));
    final url = feed.url;
    await feed.stop();
    final result = await checkForUpdate(
      feed: url,
      installed: _installed,
      platform: 'windows',
    );
    expect(result.hasUpdate, isFalse);
    expect(result.error, 'Нет связи с источником обновлений');
  });

  test('адрес источника проверяется до запроса', () async {
    final result = await checkForUpdate(
      feed: 'ftp://example.test/manifest',
      installed: _installed,
      platform: 'windows',
    );
    expect(result.hasUpdate, isFalse);
    expect(result.error, contains('http://'));
  });

  test('сохранённый адрес источника перечитывается, а плохой — нет', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = UpdateFeedStore(prefs);
    expect(store.load(), defaultUpdateFeed);

    await store.save('https://example.test/manifest.json');
    expect(store.load(), 'https://example.test/manifest.json');

    await prefs.setString('update.feed.v1', 'не адрес');
    expect(store.load(), defaultUpdateFeed);
  });

  test('точка сборки подставляется вместо публичного адреса по умолчанию',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const own = 'https://sub.example.test/u/closed/manifest.json';
    final store = UpdateFeedStore(prefs, configuredFeed: own);
    expect(store.load(), own);

    await store.save('https://other.example.test/manifest.json');
    expect(store.load(), 'https://other.example.test/manifest.json');
  });

  test('канал и ключ берутся от сборки, а не от введённого адреса', () {
    const config = ServiceConfig(
      updateFeed: 'https://sub.example.test/u/closed/manifest.json',
      updateChannel: 'closed',
      updatePublicKey: 'ключ',
    );
    // Пользователь вставил адрес публичного репозитория: адрес меняется,
    // канал и ключ остаются закрытыми — молчаливого перехода нет.
    final pasted = resolveUpdateSource(
      userFeed: defaultUpdateFeed,
      config: config,
    );
    expect(pasted.feed, defaultUpdateFeed);
    expect(pasted.channel, 'closed');
    expect(pasted.isOwn, isTrue);
    expect(pasted.publicKey, 'ключ');

    final own = resolveUpdateSource(config: config);
    expect(own.feed, config.updateFeed);

    // Открытая сборка: приватного слоя нет, канал публичный.
    final open = resolveUpdateSource();
    expect(open.channel, 'public');
    expect(open.isOwn, isFalse);
    expect(open.feed, defaultUpdateFeed);
  });

  test('сырая разметка площадки не попадает на экран', () {
    const raw = "## What's Changed\n"
        '\n'
        '* Д2-20: фрагментация рукопожатия\n'
        '* **Исправлено** восстановление соединения\n'
        '\n'
        '**Full Changelog**: https://github.com/lemluik/client-vpn/compare/v0.4.2...v0.4.3\n';
    final notes = plainReleaseNotes(raw);
    expect(notes, isNot(contains('#')));
    expect(notes, isNot(contains('*')));
    expect(notes, isNot(contains('http')));
    expect(notes, isNot(contains("What's Changed")));
    expect(notes, contains('Д2-20: фрагментация рукопожатия'));
    expect(notes, contains('Исправлено восстановление соединения'));
    expect(notes.split('\n').length, 2);
  });

  test('описание изменений ограничено по длине и числу строк', () {
    final long = List.generate(30, (i) => '* пункт $i').join('\n');
    final notes = plainReleaseNotes(long);
    expect(notes.split('\n').length, lessThanOrEqualTo(8));
    final veryLong = plainReleaseNotes('слово ' * 400);
    expect(veryLong.length, lessThanOrEqualTo(601));
    expect(plainReleaseNotes('   '), '');
  });

  test('сумма берётся по платформе, а не одна на весь манифест', () {
    final release = parseRelease({
      'version': '0.4.6',
      'files': {
        'android': {'url': 'https://example.test/a.apk', 'sha256': 'aa' * 32},
        'windows': {'url': 'https://example.test/w.zip', 'sha256': 'bb' * 32},
      },
    });
    expect(release?.sha256For('android'), 'aa' * 32);
    expect(release?.sha256For('windows'), 'bb' * 32);
    expect(release?.sha256For('macos'), isNull);
    // Плоская сумма допустима только когда файл в манифесте один.
    expect(release?.sha256, isNotNull);
    final single = parseRelease({
      'version': '0.4.6',
      'sha256': 'cc' * 32,
      'files': {'android': 'https://example.test/a.apk'},
    });
    expect(single?.sha256For('android'), 'cc' * 32);
    expect(single?.sha256For('windows'), isNull);
  });

  test('закрытый канал не получает установщик другой платформы', () {
    final release = parseRelease({
      'version': '0.4.6',
      'files': {
        'windows': {'url': 'https://example.test/w.zip', 'sha256': 'bb' * 32},
      },
    });
    expect(release?.downloadUrlFor('android', strict: true), isNull);
    expect(
      release?.downloadUrlFor('windows', strict: true),
      'https://example.test/w.zip',
    );
  });
}
