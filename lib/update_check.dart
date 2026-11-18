import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_metadata.dart';
import 'app_proxy.dart';
import 'failover.dart' show probeEndpointError;
import 'manifest_signature.dart';
import 'services/service_config.dart';

/// Проверка обновлений (позиция 31 перечня §20.1, этап R2.5; канал — Р-92).
///
/// Никакой телеметрии: запрос — один `GET` к адресу источника и, для закрытого
/// канала, один `GET` его подписи. Без идентификатора устройства, профиля и
/// версии ОС в параметрах.
///
/// Адрес своей точки раздачи в код не зашивается: он приходит из приватного
/// слоя сборки (`assets/service_config.json`, поле `update`). В открытой
/// сборке слоя нет, поэтому источником остаётся публичный репозиторий релизов
/// (гейт У-8: клиент универсальный).
const String defaultUpdateFeed =
    'https://api.github.com/repos/lemluik/client-vpn/releases/latest';

const Duration updateTimeout = Duration(seconds: 12);
const int maxUpdateResponseBytes = 256 * 1024;

/// Подпись Ed25519 — 64 байта; запас на случай текстовой обёртки не нужен,
/// больше этого размера файл подписью быть не может.
const int maxSignatureBytes = 128;

/// Ответ на проверку: либо нашли релиз новее, либо объяснение почему нет.
class UpdateResult {
  const UpdateResult.found(this.release) : error = null;
  const UpdateResult.message(this.error) : release = null;

  final ReleaseInfo? release;
  final String? error;

  bool get hasUpdate => release != null;
}

/// Релиз из манифеста. [links] — имена файлов платформы на адрес загрузки.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.links,
    this.sha256,
    this.checksums = const {},
    this.sums = const {},
    this.versionCode,
    this.channel,
    this.applicationId,
    this.signerCertSha256,
    this.minSupported,
    this.critical = false,
  });

  final String version;

  /// Описание изменений, уже очищенное от разметки: экран показывает его как
  /// есть, без `##`, `*` и ссылок на сравнение версий.
  final String notes;

  final Map<String, String> links;

  /// Контрольная сумма пакета из собственного манифеста. Companion-ассет
  /// `.sha256` на GitHub — это не сама сумма, а адрес файла с ней, поэтому сумма
  /// и ссылка на неё живут отдельно: поле [sha256] и метод [checksumUrlFor].
  final String? sha256;

  /// Companion-файлы с суммой: имя пакета (без `.sha256`) → адрес загрузки.
  final Map<String, String> checksums;

  /// Сумма по каждой платформе: `android` → sha256. Одна сумма на весь
  /// манифест больше не допускается: у платформ разные пакеты.
  final Map<String, String> sums;

  /// Код сборки (Android versionCode). Без него сравнение идёт только по
  /// строке версии, и манифест с большей версией, но меньшим кодом предложил
  /// бы обновление, которое установщик отвергнет.
  final int? versionCode;

  /// Канал сборки: `public` или `closed`. null — источник канал не объявил
  /// (страница выпусков публичного репозитория).
  final String? channel;

  final String? applicationId;
  final String? signerCertSha256;

  /// Минимальная установленная версия, которой предлагается эта сборка.
  final String? minSupported;

  final bool critical;

  /// Адрес под текущую платформу: ищем по ключу (`windows`, `android`,
  /// `macos`), потом по имени файла, потом первую ссылку. [anyAsLast] = false
  /// убирает последний шаг: сборке macOS чужой установщик не нужен.
  /// [strict] = true убирает и поиск по имени файла: закрытый канал отдаёт
  /// сборку только под свою платформу, чужой установщик не предлагается.
  String? downloadUrlFor(
    String platform, {
    bool anyAsLast = true,
    bool strict = false,
  }) {
    final direct = links[platform];
    if (direct != null && direct.isNotEmpty) return direct;
    if (strict) return null;
    for (final entry in links.entries) {
      if (entry.key.contains(platform) || entry.value.contains(platform)) {
        return entry.value;
      }
    }
    if (!anyAsLast) return null;
    return links.isEmpty ? null : links.values.first;
  }

  /// Сумма пакета под платформу. Плоская сумма манифеста допустима только
  /// когда файл в нём один: иначе она относилась бы к чужому пакету.
  String? sha256For(String platform) {
    final direct = sums[platform];
    if (direct != null && direct.isNotEmpty) return direct;
    if (sha256 == null || sha256!.isEmpty || links.length != 1) return null;
    // Сумма относится к единственному файлу манифеста. Если файл назван
    // платформой, чужой платформе она не достаётся: иначе windows сверял бы
    // пакет Android суммой от APK.
    final owner = links.keys.single;
    return (owner == platform || owner == 'download') ? sha256 : null;
  }

  /// Адрес companion-файла с SHA-256 для пакета [downloadUrl]: ищем ассет,
  /// ссылка которого ровно эта же или эта плюс суффикс `.sha256`.
  /// `null` — суммы на площадке нет.
  String? checksumUrlFor(String downloadUrl) {
    if (checksums.isEmpty) return null;
    for (final entry in links.entries) {
      if (entry.value != downloadUrl) continue;
      final sum = checksums[entry.key] ?? checksums['${entry.key}.sha256'];
      if (sum != null) return sum;
    }
    return null;
  }
}

/// Разбирает манифест релиза. Поддержаны два формата, и оба — без серверной
/// логики: страница выпусков публичного репозитория и собственный манифест
/// точки раздачи (Р-92).
ReleaseInfo? parseRelease(Object? json) {
  if (json is! Map) return null;

  // Формат страницы выпусков GitHub: tag_name + assets[].browser_download_url.
  final tag = json['tag_name'];
  if (tag is String && tag.isNotEmpty) {
    final assets = json['assets'];
    final links = <String, String>{};
    final checksums = <String, String>{};
    if (assets is List) {
      for (final asset in assets.whereType<Map>()) {
        final name = asset['name'];
        final url = asset['browser_download_url'];
        if (name is String && url is String && url.isNotEmpty) {
          // Companion-файл с SHA-256 (`app.apk.sha256`) — не ссылка на пакет.
          final lower = name.toLowerCase();
          if (lower.endsWith('.sha256')) {
            checksums[lower.substring(0, lower.length - '.sha256'.length)] = url;
            continue;
          }
          links[lower] = url;
        }
      }
    }
    return ReleaseInfo(
      version: normalizeVersion(tag),
      notes: plainReleaseNotes(json['body'] is String ? json['body'] as String : ''),
      links: links,
      checksums: checksums,
    );
  }

  // Формат собственного манифеста: version, notes, files по имени платформы.
  final version = json['version'];
  if (version is! String || version.isEmpty) return null;
  final links = <String, String>{};
  final sums = <String, String>{};
  String? manifestSha;
  final files = json['files'];
  if (files is Map) {
    files.forEach((key, value) {
      if (key is! String) return;
      final lower = key.toLowerCase();
      if (value is String && value.isNotEmpty) {
        links[lower] = value;
        return;
      }
      // Раздел вида {"android": {"url": …, "sha256": …}}.
      if (value is Map) {
        final url = value['url'];
        if (url is String && url.isNotEmpty) links[lower] = url;
        final sum = value['sha256'];
        if (sum is String && sum.isNotEmpty) {
          sums[lower] = sum.toLowerCase();
          manifestSha = sum.toLowerCase();
        }
      }
    });
  }
  final single = json['url'];
  if (links.isEmpty && single is String && single.isNotEmpty) {
    links['download'] = single;
  }
  final flat = json['sha256'];
  if (manifestSha == null && flat is String && flat.isNotEmpty) {
    manifestSha = flat.toLowerCase();
  }
  final code = json['versionCode'];
  final minSupported = json['minSupported'];
  return ReleaseInfo(
    version: normalizeVersion(version),
    notes: plainReleaseNotes(json['notes'] is String ? json['notes'] as String : ''),
    links: links,
    sha256: manifestSha,
    sums: sums,
    versionCode: code is int ? code : (code is num ? code.toInt() : null),
    channel: _text(json['channel']),
    applicationId: _text(json['applicationId']),
    signerCertSha256: _text(json['signerCertSha256'])?.toLowerCase(),
    minSupported: minSupported is String && minSupported.isNotEmpty
        ? normalizeVersion(minSupported)
        : null,
    critical: json['critical'] == true,
  );
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// `v0.4.0+7`, `0.4.0` и `release-0.4.0` приводятся к `0.4.0`.
String normalizeVersion(String raw) {
  final match = RegExp(r'\d+(?:\.\d+){0,3}').firstMatch(raw.trim());
  return match == null ? '' : match.group(0)!;
}

/// Сравнение по числом разрядам: `0.10.0` новее `0.9.0`.
int compareVersions(String left, String right) {
  final a = normalizeVersion(left).split('.');
  final b = normalizeVersion(right).split('.');
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final x = i < a.length ? int.tryParse(a[i]) ?? 0 : 0;
    final y = i < b.length ? int.tryParse(b[i]) ?? 0 : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Короткое описание изменений без разметки.
///
/// Сырой Markdown на экране читается как мусор: `## What's Changed`, звёздочки
/// пунктов и ссылка на сравнение версий. Здесь остаются только строки описания;
/// заголовки-шаблоны и строки-ссылки убираются, длина ограничена — экран
/// обновления не превращается в простыню.
String plainReleaseNotes(String raw, {int maxLines = 8, int maxLength = 600}) {
  if (raw.trim().isEmpty) return '';
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // Изображения и ссылки: картинку убираем, у ссылки оставляем её текст.
  text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  text = text.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '');
  text = text.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1) ?? '');
  text = text.replaceAllMapped(
      RegExp(r'__([^_]+)__'), (m) => m.group(1) ?? '');
  text = text.replaceAllMapped(
      RegExp(r'\*([^*\n]+)\*'), (m) => m.group(1) ?? '');
  text = text.replaceAll('`', '');

  final kept = <String>[];
  for (final line in text.split('\n')) {
    var value = line.trim();
    if (value.isEmpty) continue;
    // Заголовок-шаблоны площадок: описания изменений в них нет.
    final heading = value.replaceFirst(RegExp(r'^#{1,6}\s*'), '').trim();
    if (RegExp(r"^(what's changed|changelog|full changelog|полный список изменений)$",
            caseSensitive: false)
        .hasMatch(heading)) {
      continue;
    }
    value = heading;
    if (RegExp(r'^([-*_]\s*){3,}$').hasMatch(value)) continue;
    if (RegExp(r'^https?://\S+$').hasMatch(value)) continue;
    if (RegExp(r'^(full changelog|полный список изменений)\b',
            caseSensitive: false)
        .hasMatch(value)) {
      continue;
    }
    value = value.replaceFirst(RegExp(r'^[-*+]\s+'), '').trim();
    if (value.isEmpty) continue;
    kept.add(value);
    if (kept.length >= maxLines) break;
  }
  var result = kept.join('\n');
  if (result.length > maxLength) {
    result = '${result.substring(0, maxLength).trimRight()}…';
  }
  return result;
}

/// Платформа текущей сборки именем манифеста.
String currentPlatformName() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  return Platform.operatingSystem;
}

/// Решение по манифесту: предложить можно только более новую совместимую
/// сборку того же канала. Каждый отказ — своя понятная формулировка, а не
/// общее «обновлений нет»: пользователь должен видеть причину.
///
/// Подпись манифеста проверяется раньше, в [checkForUpdate]: сюда приходит
/// уже проверенный источник.
UpdateResult evaluateRelease({
  required ReleaseInfo release,
  required AppMetadata installed,
  required String platform,
  required String channel,
}) {
  if (!installed.isKnown) {
    return const UpdateResult.message(
      'Не удалось прочитать установленную версию — проверка обновления недоступна',
    );
  }

  final own = channel == 'closed';
  final declared = release.channel;
  if (own && declared != 'closed') {
    return const UpdateResult.message(
      'Источник не подтвердил закрытый канал сборки — обновление не предлагается',
    );
  }
  if (!own && declared != null && declared != 'public') {
    return const UpdateResult.message(
      'Источник предлагает сборку другого канала — обновление не предлагается',
    );
  }

  final strict = own;
  final url = release.downloadUrlFor(platform, anyAsLast: !strict, strict: strict);
  if (url == null || url.isEmpty) {
    return const UpdateResult.message('В источнике нет сборки для этой платформы');
  }
  if (own && release.sha256For(platform) == null) {
    return const UpdateResult.message(
      'Источник не указал контрольную сумму сборки — обновление не предлагается',
    );
  }

  // Совместимость установки поверх: другое приложение или другая подпись
  // означают, что обновление потребует удаления данных. Не предлагаем.
  final appId = release.applicationId;
  if (appId != null &&
      installed.applicationId != null &&
      appId != installed.applicationId) {
    return const UpdateResult.message(
      'Сборка предназначена для другого приложения — обновление не предлагается',
    );
  }
  final signer = release.signerCertSha256;
  if (own && platform == 'android') {
    if (installed.signerSha256 == null) {
      return const UpdateResult.message(
        'Не удалось прочитать подпись установленного приложения — обновление не предлагается',
      );
    }
    if (signer == null || signer != installed.signerSha256) {
      return const UpdateResult.message(
        'Подпись сборки не совпадает с подписью установленного приложения — обновление поверх невозможно',
      );
    }
  }

  final minSupported = release.minSupported;
  if (minSupported != null &&
      minSupported.isNotEmpty &&
      compareVersions(installed.versionName, minSupported) < 0) {
    return UpdateResult.message(
      'Сборка требует установленную версию не ниже $minSupported',
    );
  }

  final byName = compareVersions(release.version, installed.versionName);
  final releaseCode = release.versionCode;
  final byCode = (releaseCode != null && installed.versionCode > 0)
      ? releaseCode.compareTo(installed.versionCode)
      : null;

  if (byName < 0 || (byCode != null && byCode < 0)) {
    return const UpdateResult.message(
      'Установлена более новая сборка — понижение версии не предлагается',
    );
  }
  if (byName == 0 && (byCode == null || byCode <= 0)) {
    return const UpdateResult.message('Обновлений нет');
  }
  if (byName > 0 && byCode != null && byCode <= 0) {
    return const UpdateResult.message(
      'Источник предлагает версию новее, но код сборки не больше установленного — обновление не предлагается',
    );
  }
  return UpdateResult.found(release);
}

/// Проверка по адресу [feed]. Ошибки не бросаются наружу: экран показывает
/// нейтральную формулировку, а недоступный источник не должен выглядеть как
/// сбой подключения.
///
/// Молчаливого перехода на другой источник нет: недоступность своей точки —
/// это сообщение об ошибке, а не запрос к публичному репозиторию. Для закрытого
/// канала подпись обязательна, и без неё манифест не разбирается.
Future<UpdateResult> checkForUpdate({
  required String feed,
  required AppMetadata installed,
  String channel = 'public',
  String? publicKey,
  String? platform,
}) async {
  final invalid = probeEndpointError(feed);
  if (invalid != null) return UpdateResult.message(invalid);

  final own = channel == 'closed';
  final target = platform ?? currentPlatformName();
  final uri = Uri.parse(feed.trim());
  if (own && uri.scheme != 'https' && !_isLoopback(uri)) {
    return const UpdateResult.message(
      'Источник закрытого канала должен работать по защищённому соединению (https)',
    );
  }
  if (own && (publicKey == null || publicKey.trim().isEmpty)) {
    return const UpdateResult.message(
      'Не задан ключ проверки подписи источника обновлений',
    );
  }

  final client = HttpClient();
  // Без этого HttpClient смотрит только переменные окружения (ТД-15).
  client.findProxy = AppProxy.findProxy;
  client.connectionTimeout = updateTimeout;
  try {
    final manifest = await _get(client, uri, maxUpdateResponseBytes);
    if (manifest == null) {
      return const UpdateResult.message('Нет связи с источником обновлений');
    }
    if (manifest.status != HttpStatus.ok) {
      return UpdateResult.message('Источник ответил кодом ${manifest.status}');
    }
    final manifestBytes = manifest.bytes;
    if (manifestBytes == null) {
      return const UpdateResult.message('Ответ источника слишком большой');
    }
    if (manifestBytes.isEmpty) {
      return const UpdateResult.message('Источник вернул пустой ответ');
    }

    if (own) {
      final signatureFetch = await _get(
        client,
        Uri.parse(signatureUrlFor(feed)),
        maxSignatureBytes,
      );
      final signature = signatureFetch?.status == HttpStatus.ok
          ? signatureFetch?.bytes
          : null;
      if (signature == null || signature.isEmpty) {
        return const UpdateResult.message(
          'Не удалось получить подпись источника обновлений',
        );
      }
      final ok = verifyManifestSignature(
        manifestBytes: manifestBytes,
        signature: signature,
        publicKeyBase64: publicKey!,
      );
      if (!ok) {
        return const UpdateResult.message(
          'Подпись источника обновлений не совпадает — обновление не предлагается',
        );
      }
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes));
    } on FormatException {
      return const UpdateResult.message('Источник вернул не JSON');
    }
    final release = parseRelease(decoded);
    if (release == null) {
      return const UpdateResult.message('Источник вернул непонятный набор данных');
    }
    return evaluateRelease(
      release: release,
      installed: installed,
      platform: target,
      channel: channel,
    );
  } on TimeoutException {
    return const UpdateResult.message('Источник не ответил вовремя');
  } on SocketException {
    return const UpdateResult.message('Нет связи с источником обновлений');
  } on HandshakeException {
    return const UpdateResult.message('Не удалось установить защищённое соединение');
  } finally {
    client.close(force: true);
  }
}

/// Петлевой адрес — стенд проверки на этой же машине. Требование https к нему
/// не применяется: снаружи петлю не подменить, а без исключения проверку
/// подписи и каналов нельзя прогнать локально.
bool _isLoopback(Uri uri) =>
    uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1';

/// Один GET с ограничением размера. null — сеть не ответила; код ответа и
/// байты возвращаются раздельно, чтобы «код 404» и «слишком большой ответ»
/// не выглядели как отсутствие связи.
Future<_Fetch?> _get(HttpClient client, Uri uri, int limit) async {
  final request = await client.getUrl(uri).timeout(updateTimeout);
  final response = await request.close().timeout(updateTimeout);
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    return _Fetch(response.statusCode, const []);
  }
  final bytes = <int>[];
  await for (final chunk in response) {
    bytes.addAll(chunk);
    if (bytes.length > limit) return _Fetch(response.statusCode, null);
  }
  return _Fetch(response.statusCode, bytes);
}

class _Fetch {
  const _Fetch(this.status, this.bytes);

  final int status;

  /// null — ответ превысил предел размера.
  final List<int>? bytes;
}

/// Источник проверки обновлений: адрес, канал и ключ проверки подписи.
///
/// Канал и ключ всегда от конфигурации сборки, а не от введённого адреса:
/// иначе вставленная ссылка на публичный репозиторий молча переводила бы
/// закрытую сборку на открытый пакет.
class UpdateSource {
  const UpdateSource({
    required this.feed,
    required this.channel,
    this.publicKey,
  });

  final String feed;
  final String channel;
  final String? publicKey;

  bool get isOwn => channel == 'closed';
}

/// Разрешение источника: явный адрес пользователя, иначе точка из конфигурации
/// сборки, иначе публичный канал открытой сборки.
UpdateSource resolveUpdateSource({
  String? userFeed,
  ServiceConfig? config,
}) {
  final configured = config?.updateFeed;
  final saved = userFeed?.trim();
  final feed = (saved != null && saved.isNotEmpty && probeEndpointError(saved) == null)
      ? saved
      : (configured != null && configured.isNotEmpty
          ? configured
          : defaultUpdateFeed);
  return UpdateSource(
    feed: feed,
    channel: config?.updateChannel ?? 'public',
    publicKey: config?.updatePublicKey,
  );
}

/// Адрес источника обновлений: значение пользователя или точка сборки.
class UpdateFeedStore {
  UpdateFeedStore(this._prefs, {this.configuredFeed});

  static const _key = 'update.feed.v1';
  final SharedPreferences _prefs;

  /// Точка из приватного слоя сборки. Без неё источник по умолчанию —
  /// публичный репозиторий (открытая сборка).
  final String? configuredFeed;

  String load() {
    final saved = _prefs.getString(_key);
    if (saved != null && saved.isNotEmpty && probeEndpointError(saved) == null) {
      return saved;
    }
    final configured = configuredFeed;
    return configured == null || configured.isEmpty
        ? defaultUpdateFeed
        : configured;
  }

  Future<void> save(String feed) => _prefs.setString(_key, feed.trim());
}