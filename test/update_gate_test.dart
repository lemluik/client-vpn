import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:client_vpn/app_metadata.dart';
import 'package:client_vpn/update_check.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';

/// Шесть сценариев владельца на закрытом канале (Р-92). Источник — настоящий
/// петлевой HTTP-стенд, подпись — настоящая Ed25519, манифест подписывается до
/// отдачи. Каждый отказ проверяется парой: рабочее значение проходит,
/// испорченное — отказывает. Без такой пары тест не отличает проверку от
/// случайного совпадения.
const String _cert =
    'f579799b71032b9b8bde11cb7d81e0eca7af4b01b0a43be674c319baffb7be4b';
const String _appId = 'com.clientvpn.client_vpn';

const AppMetadata _installed = AppMetadata(
  versionName: '0.4.5',
  versionCode: 3,
  applicationId: _appId,
  signerSha256: _cert,
);

class _Stand {
  _Stand(this._server, this.requests);

  final HttpServer _server;
  final List<String> requests;

  String get url => 'http://127.0.0.1:${_server.port}/manifest';

  Future<void> stop() => _server.close(force: true);
}

Future<_Stand> _stand({
  required List<int> manifest,
  List<int>? signature,
  int manifestStatus = 200,
}) async {
  final requests = <String>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    requests.add(request.uri.path);
    final isSig = request.uri.path.endsWith('.sig');
    final body = isSig ? signature : manifest;
    request.response.statusCode = body == null ? 404 : manifestStatus;
    if (body != null) request.response.add(body);
    await request.response.close();
  });
  return _Stand(server, requests);
}

Map<String, Object?> _manifest({
  String version = '0.4.6',
  int versionCode = 4,
  Object? channel = 'closed',
  Object? applicationId = _appId,
  Object? signer = _cert,
  String platform = 'android',
  bool withSum = true,
  String? minSupported,
  String notes = 'Исправлено восстановление соединения',
}) {
  final file = <String, Object?>{
    'url': 'https://sub.example.test/u/closed/ClientVPN-v$version-Android.apk',
    'size': 46795765,
  };
  if (withSum) file['sha256'] = 'bf8dd037' * 8;
  return {
    'version': version,
    'versionCode': versionCode,
    'channel': ?channel,
    'applicationId': ?applicationId,
    'signerCertSha256': ?signer,
    'minSupported': ?minSupported,
    'notes': notes,
    'files': {platform: file},
  };
}

void main() {
  final key = ed.newKeyFromSeed(Uint8List.fromList(List<int>.filled(32, 11)));
  final pub = base64.encode(ed.public(key).bytes);
  final otherKey =
      ed.newKeyFromSeed(Uint8List.fromList(List<int>.filled(32, 22)));
  final otherPub = base64.encode(ed.public(otherKey).bytes);

  List<int> bytesOf(Map<String, Object?> manifest) =>
      utf8.encode(jsonEncode(manifest));

  Future<_Stand> signed(
    Map<String, Object?> manifest, {
    List<int>? signature,
    int manifestStatus = 200,
    bool serveSignature = true,
  }) async {
    final body = bytesOf(manifest);
    final stand = await _stand(
      manifest: body,
      signature: serveSignature
          ? (signature ?? ed.sign(key, Uint8List.fromList(body)))
          : null,
      manifestStatus: manifestStatus,
    );
    addTearDown(stand.stop);
    return stand;
  }

  Future<UpdateResult> check(
    _Stand stand, {
    AppMetadata installed = _installed,
    String channel = 'closed',
    String? publicKey,
    bool noKey = false,
    String platform = 'android',
  }) =>
      checkForUpdate(
        feed: stand.url,
        installed: installed,
        channel: channel,
        publicKey: noKey ? null : (publicKey ?? pub),
        platform: platform,
      );

  test('сценарий 1: старая версия получает новую сборку своего канала',
      () async {
    final stand = await signed(_manifest());
    final result = await check(stand);
    expect(result.error, isNull);
    expect(result.hasUpdate, isTrue);
    expect(result.release?.version, '0.4.6');
    expect(result.release?.versionCode, 4);
    expect(result.release?.notes, 'Исправлено восстановление соединения');
    expect(
      result.release?.downloadUrlFor('android', strict: true),
      contains('ClientVPN-v0.4.6-Android.apk'),
    );
    expect(result.release?.sha256For('android'), 'bf8dd037' * 8);
    // Запрошены только манифест и его подпись, никаких других адресов.
    expect(stand.requests, ['/manifest', '/manifest.sig']);
  });

  test('сценарий 2: текущая версия — «Обновлений нет»', () async {
    final same = await signed(_manifest(version: '0.4.5', versionCode: 3));
    expect((await check(same)).error, 'Обновлений нет');

    // Та же строка версии, но больший код сборки — обновление предлагается:
    // две сборки 0.4.5 различаются только кодом.
    final recoded = await signed(_manifest(version: '0.4.5', versionCode: 4));
    expect((await check(recoded)).hasUpdate, isTrue);
  });

  test('сценарий 3: более новая установленная — понижение запрещено',
      () async {
    const newer = AppMetadata(
      versionName: '0.4.7',
      versionCode: 5,
      applicationId: _appId,
      signerSha256: _cert,
    );
    final stand = await signed(_manifest());
    final result = await check(stand, installed: newer);
    expect(result.hasUpdate, isFalse);
    expect(result.error, contains('понижение версии не предлагается'));

    // Меньший код сборки при той же строке версии — тоже понижение.
    const sameName = AppMetadata(
      versionName: '0.4.6',
      versionCode: 9,
      applicationId: _appId,
      signerSha256: _cert,
    );
    final byCode = await check(stand, installed: sameName);
    expect(byCode.hasUpdate, isFalse);
    expect(byCode.error, contains('понижение версии не предлагается'));
  });

  test('строка версии новее, а код сборки не больше — отказ, а не предложение',
      () async {
    final stand = await signed(_manifest(version: '0.4.6', versionCode: 3));
    final result = await check(stand);
    expect(result.hasUpdate, isFalse);
    expect(result.error, contains('код сборки не больше установленного'));

    // Control: тот же манифест с большим кодом проходит.
    final ok = await signed(_manifest(version: '0.4.6', versionCode: 4));
    expect((await check(ok)).hasUpdate, isTrue);
  });

  test('сценарий 4: неверная подпись источника — понятный отказ', () async {
    final manifest = _manifest();
    final body = bytesOf(manifest);
    final good = ed.sign(key, Uint8List.fromList(body));

    final valid = await signed(manifest);
    expect((await check(valid)).hasUpdate, isTrue);

    final tamperedSig = Uint8List.fromList(good)..[0] ^= 0x01;
    final badSig = await signed(manifest, signature: tamperedSig);
    expect(
      (await check(badSig)).error,
      'Подпись источника обновлений не совпадает — обновление не предлагается',
    );

    // Манифест изменён после подписания: подпись над другими байтами.
    final changed = await signed(
      _manifest(version: '9.9.9'),
      signature: good,
    );
    expect((await check(changed)).error, contains('Подпись источника'));

    // Подпись другим ключом при закреплённом нашем.
    final foreign = await signed(
      manifest,
      signature: ed.sign(otherKey, Uint8List.fromList(body)),
    );
    expect((await check(foreign)).error, contains('Подпись источника'));

    // Подписи нет совсем.
    final missing = await signed(manifest, serveSignature: false);
    expect(
      (await check(missing)).error,
      'Не удалось получить подпись источника обновлений',
    );

    // Ключ в сборке не задан — проверка невозможна, обновление не предлагается.
    final noKey = await signed(manifest);
    expect(
      (await check(noKey, noKey: true)).error,
      'Не задан ключ проверки подписи источника обновлений',
    );
  });

  test('сценарий 5: чужой канал не предлагается', () async {
    // Закрытая сборка, источник объявил публичный канал.
    final publicManifest = await signed(_manifest(channel: 'public'));
    expect(
      (await check(publicManifest)).error,
      'Источник не подтвердил закрытый канал сборки — обновление не предлагается',
    );

    // Канал не объявлен вовсе (страница выпусков публичного репозитория).
    final undeclared = await signed(_manifest(channel: null));
    expect((await check(undeclared)).error, contains('не подтвердил закрытый канал'));

    // Control: объявленный закрытый канал проходит.
    final own = await signed(_manifest());
    expect((await check(own)).hasUpdate, isTrue);

    // Открытая сборка не получает закрытый пакет.
    final closedForOpen = await signed(_manifest());
    final openResult = await check(
      closedForOpen,
      channel: 'public',
      installed: const AppMetadata(versionName: '0.4.3', versionCode: 1),
    );
    expect(openResult.hasUpdate, isFalse);
    expect(openResult.error, contains('другого канала'));
  });

  test('сценарий 6: недоступный источник — ошибка, а не переход на GitHub',
      () async {
    final dead = await signed(_manifest());
    final url = dead.url;
    await dead.stop();
    final offline = await checkForUpdate(
      feed: url,
      installed: _installed,
      channel: 'closed',
      publicKey: pub,
      platform: 'android',
    );
    expect(offline.hasUpdate, isFalse);
    expect(offline.error, 'Нет связи с источником обновлений');

    final notFound = await signed(_manifest(), manifestStatus: 404);
    final missing = await check(notFound);
    expect(missing.hasUpdate, isFalse);
    expect(missing.error, 'Источник ответил кодом 404');
    // Запрос ушёл только к своему источнику: публичный репозиторий не вызывался.
    expect(notFound.requests, ['/manifest']);

    final garbage = await _stand(manifest: utf8.encode('не json'));
    addTearDown(garbage.stop);
    expect(
      (await check(garbage)).error,
      'Не удалось получить подпись источника обновлений',
    );
  });

  test('закрытый канал требует https, петлевой стенд исключён явно', () async {
    final result = await checkForUpdate(
      feed: 'http://sub.example.test/u/closed/manifest.json',
      installed: _installed,
      channel: 'closed',
      publicKey: pub,
      platform: 'android',
    );
    expect(result.hasUpdate, isFalse);
    expect(result.error, contains('https'));
  });

  test('установка поверх: чужое приложение или чужая подпись не предлагаются',
      () async {
    final foreignApp = await signed(_manifest(applicationId: 'com.other.app'));
    expect(
      (await check(foreignApp)).error,
      'Сборка предназначена для другого приложения — обновление не предлагается',
    );

    final foreignSigner = await signed(_manifest(signer: 'cd' * 32));
    expect(
      (await check(foreignSigner)).error,
      contains('Подпись сборки не совпадает'),
    );

    // Подпись установленного приложения не читается — поверх ставить нельзя.
    const noSigner = AppMetadata(
      versionName: '0.4.5',
      versionCode: 3,
      applicationId: _appId,
    );
    final unreadable = await signed(_manifest());
    expect(
      (await check(unreadable, installed: noSigner)).error,
      'Не удалось прочитать подпись установленного приложения — обновление не предлагается',
    );

    // Control: своя подпись и своё приложение проходят.
    final ok = await signed(_manifest());
    expect((await check(ok)).hasUpdate, isTrue);
  });

  test('без контрольной суммы закрытый канал обновление не предлагает',
      () async {
    final noSum = await signed(_manifest(withSum: false));
    expect(
      (await check(noSum)).error,
      'Источник не указал контрольную сумму сборки — обновление не предлагается',
    );
    final withSum = await signed(_manifest());
    expect((await check(withSum)).hasUpdate, isTrue);
  });

  test('нечитаемая установленная версия не сравнивается наугад', () async {
    final stand = await signed(_manifest());
    final result = await check(
      stand,
      installed: const AppMetadata(versionName: '', versionCode: 0),
    );
    expect(result.hasUpdate, isFalse);
    expect(result.error, contains('Не удалось прочитать установленную версию'));
  });

  test('сборка для другой платформы не подставляется', () async {
    final windowsOnly = await signed(_manifest(platform: 'windows'));
    expect(
      (await check(windowsOnly)).error,
      'В источнике нет сборки для этой платформы',
    );
    // Открытая сборка на macOS чужой установщик тоже не получает.
    final open = await check(
      windowsOnly,
      channel: 'public',
      platform: 'macos',
      installed: const AppMetadata(versionName: '0.4.3', versionCode: 1),
    );
    expect(open.hasUpdate, isFalse);
  });

  test('minSupported отсекает слишком старую установленную версию', () async {
    final stand = await signed(_manifest(minSupported: '0.4.6'));
    final result = await check(stand);
    expect(result.hasUpdate, isFalse);
    expect(result.error, 'Сборка требует установленную версию не ниже 0.4.6');

    const recent = AppMetadata(
      versionName: '0.4.6',
      versionCode: 4,
      applicationId: _appId,
      signerSha256: _cert,
    );
    final newer = await signed(_manifest(version: '0.4.7', versionCode: 5,
        minSupported: '0.4.6'));
    expect((await check(newer, installed: recent)).hasUpdate, isTrue);
  });

  test('критичность читается из манифеста, а не задаётся в коде', () async {
    final stand = await signed({
      ..._manifest(),
      'critical': true,
    });
    final result = await check(stand);
    expect(result.release?.critical, isTrue);

    final ordinary = await signed(_manifest());
    expect((await check(ordinary)).release?.critical, isFalse);
  });

  test('чужой ключ в сборке не принимает подпись нашего источника', () async {
    final stand = await signed(_manifest());
    final result = await check(stand, publicKey: otherPub);
    expect(result.hasUpdate, isFalse);
    expect(result.error, contains('Подпись источника'));
  });
}