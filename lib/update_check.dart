import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_proxy.dart';
import 'failover.dart' show probeEndpointError;

/// Проверка обновлений (позиция 31 перечня §20.1, этап R2.5).
///
/// Никакой телеметрии: запрос — один `GET` к адресу, который выбрал сборщик
/// релиза или пользователь, без идентификатора устройства, профиля и версии
/// ОС в параметрах. Адрес источника не зашивается в код как наш адрес
/// (гейт У-8): по умолчанию это публичный репозиторий с релизами, а поле
/// в настройках принимает любой другой — например второй канал раздачи
/// (позиция Р-25), если владелец поднимет статический манифест.
const String defaultUpdateFeed =
    'https://api.github.com/repos/lemluik/client-vpn/releases/latest';

const Duration updateTimeout = Duration(seconds: 12);
const int maxUpdateResponseBytes = 256 * 1024;

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
  });

  final String version;
  final String notes;
  final Map<String, String> links;

  /// Адрес под текущую платформу: ищем по ключу (`windows`, `android`),
  /// потом по имени файла, потом первую ссылку.
  String? downloadUrlFor(String platform) {
    final direct = links[platform];
    if (direct != null && direct.isNotEmpty) return direct;
    for (final entry in links.entries) {
      if (entry.key.contains(platform) || entry.value.contains(platform)) {
        return entry.value;
      }
    }
    return links.isEmpty ? null : links.values.first;
  }
}

/// Разбирает манифест релиза. Поддержаны два формата, и оба — без серверной
/// логики: страница выпусков публичного репозитория и простой JSON на любом
/// хостинге (второй канал раздачи).
ReleaseInfo? parseRelease(Object? json) {
  if (json is! Map) return null;

  // Формат страницы выпусков GitHub: tag_name + assets[].browser_download_url.
  final tag = json['tag_name'];
  if (tag is String && tag.isNotEmpty) {
    final assets = json['assets'];
    final links = <String, String>{};
    if (assets is List) {
      for (final asset in assets.whereType<Map>()) {
        final name = asset['name'];
        final url = asset['browser_download_url'];
        if (name is String && url is String && url.isNotEmpty) {
          links[name.toLowerCase()] = url;
        }
      }
    }
    return ReleaseInfo(
      version: normalizeVersion(tag),
      notes: json['body'] is String ? json['body'] as String : '',
      links: links,
    );
  }

  // Формат собственного манифеста: version, notes, files по имени платформы.
  final version = json['version'];
  if (version is! String || version.isEmpty) return null;
  final links = <String, String>{};
  final files = json['files'];
  if (files is Map) {
    files.forEach((key, value) {
      if (key is String && value is String && value.isNotEmpty) {
        links[key.toLowerCase()] = value;
      }
    });
  }
  final single = json['url'];
  if (links.isEmpty && single is String && single.isNotEmpty) {
    links['download'] = single;
  }
  return ReleaseInfo(
    version: normalizeVersion(version),
    notes: json['notes'] is String ? json['notes'] as String : '',
    links: links,
  );
}

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

/// Проверка по адресу [feed]. Ошибки не бросаются наружу: экран показывает
/// нейтральную формулировку, а недоступный источник не должен выглядеть как
/// сбой подключения.
Future<UpdateResult> checkForUpdate({
  required String feed,
  required String currentVersion,
}) async {
  final invalid = probeEndpointError(feed);
  if (invalid != null) return UpdateResult.message(invalid);

  final client = HttpClient();
  // Без этого HttpClient смотрит только переменные окружения (ТД-15).
  client.findProxy = AppProxy.findProxy;
  client.connectionTimeout = updateTimeout;
  try {
    final uri = Uri.parse(feed.trim());
    final request = await client.getUrl(uri).timeout(updateTimeout);
    // Заголовок нужен только площадке GitHub; на статическом манифесте он
    // лишний, поэтому не отправляем ничего, кроме стандартного.
    final response = await request.close().timeout(updateTimeout);
    if (response.statusCode != HttpStatus.ok) {
      return UpdateResult.message(
        'Источник ответил кодом ${response.statusCode}',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxUpdateResponseBytes) {
        return const UpdateResult.message('Ответ источника слишком большой');
      }
    }
    final release = parseRelease(jsonDecode(utf8.decode(bytes)));
    if (release == null) {
      return const UpdateResult.message('Источник вернул непонятный набор данных');
    }
    if (compareVersions(release.version, currentVersion) <= 0) {
      return const UpdateResult.message('Обновлений нет');
    }
    return UpdateResult.found(release);
  } on TimeoutException {
    return const UpdateResult.message('Источник не ответил вовремя');
  } on SocketException {
    return const UpdateResult.message('Нет связи с источником обновлений');
  } on HandshakeException {
    return const UpdateResult.message('Не удалось установить защищённое соединение');
  } on FormatException {
    return const UpdateResult.message('Источник вернул не JSON');
  } finally {
    client.close(force: true);
  }
}

/// Адрес источника обновлений: значение пользователя или канал релиза.
class UpdateFeedStore {
  UpdateFeedStore(this._prefs);

  static const _key = 'update.feed.v1';
  final SharedPreferences _prefs;

  String load() {
    final saved = _prefs.getString(_key);
    return saved == null || saved.isEmpty || probeEndpointError(saved) != null
        ? defaultUpdateFeed
        : saved;
  }

  Future<void> save(String feed) => _prefs.setString(_key, feed.trim());
}
