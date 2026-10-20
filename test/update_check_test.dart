import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/about_screen.dart' show clientVersion;
import 'package:client_vpn/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('источник с релизом новее текущей версии найден', () async {
    final feed = await _jsonFeed({
      'version': '9.9.9',
      'notes': 'тест',
      'files': {'windows': 'https://example.test/win.zip'},
    });
    addTearDown(feed.stop);
    final result = await checkForUpdate(
      feed: feed.url,
      currentVersion: clientVersion,
    );
    expect(result.hasUpdate, isTrue);
    expect(result.release?.version, '9.9.9');
    expect(result.error, isNull);
  });

  test('равная и более старая версия обновлением не считаются', () async {
    final feed = await _jsonFeed({'version': clientVersion, 'files': {}});
    addTearDown(feed.stop);
    final result = await checkForUpdate(
      feed: feed.url,
      currentVersion: clientVersion,
    );
    expect(result.hasUpdate, isFalse);
    expect(result.error, 'Обновлений нет');
  });

  test('плохой ответ источника превращается в нейтральное сообщение', () async {
    final notFound = await _feed(utf8.encode('{}'), status: 404);
    addTearDown(notFound.stop);
    final code = await checkForUpdate(
      feed: notFound.url,
      currentVersion: clientVersion,
    );
    expect(code.error, contains('404'));

    final garbage = await _feed(utf8.encode('не json совсем'));
    addTearDown(garbage.stop);
    final broken = await checkForUpdate(
      feed: garbage.url,
      currentVersion: clientVersion,
    );
    expect(broken.error, 'Источник вернул не JSON');

    final big = await _feed(List.filled(maxUpdateResponseBytes + 10, 0x30));
    addTearDown(big.stop);
    final oversize = await checkForUpdate(
      feed: big.url,
      currentVersion: clientVersion,
    );
    expect(oversize.error, contains('слишком большой'));
  });

  test('мёртвый источник не выглядит как сбой подключения', () async {
    final feed = await _feed(utf8.encode('{}'));
    final url = feed.url;
    await feed.stop();
    final result = await checkForUpdate(feed: url, currentVersion: clientVersion);
    expect(result.hasUpdate, isFalse);
    expect(result.error, 'Нет связи с источником обновлений');
  });

  test('адрес источника проверяется до запроса', () async {
    final result = await checkForUpdate(
      feed: 'ftp://example.test/manifest',
      currentVersion: clientVersion,
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
}
