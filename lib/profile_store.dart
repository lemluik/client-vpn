import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'profile_config.dart';
import 'provider.dart';
import 'share_link.dart';
import 'vpn_config.dart';

/// Откуда взят профиль: ссылки, подписка провайдера или файл пользователя.
enum ProfileKind { links, subscription, file }

/// Один сохранённый профиль подключения.
class StoredProfile {
  const StoredProfile({
    required this.id,
    required this.name,
    required this.kind,
    required this.addedAt,
    this.links = const [],
    this.providerId,
    this.rawJson,
    this.path,
  });

  final String id;
  final String name;
  final ProfileKind kind;
  final DateTime addedAt;

  /// Ссылки профилей — для видов [ProfileKind.links] и [ProfileKind.subscription].
  final List<ShareLink> links;

  /// Провайдер подписки — только для [ProfileKind.subscription].
  final String? providerId;

  /// Полное содержимое файла ядра — только для [ProfileKind.file].
  final String? rawJson;

  /// Путь файла на диске. Есть только на десктопе, где ядро читает файл само.
  final String? path;

  bool get canStart => kind == ProfileKind.file
      ? (rawJson?.isNotEmpty ?? false)
      : links.isNotEmpty;

  StoredProfile copyWith({String? name, List<ShareLink>? links}) =>
      StoredProfile(
        id: id,
        name: name ?? this.name,
        kind: kind,
        addedAt: addedAt,
        links: links ?? this.links,
        providerId: providerId,
        rawJson: rawJson,
        path: path,
      );

  /// Ссылки сохраняем исходным текстом: это компактнее и не зависит от того,
  /// какие поля появятся у модели разбора.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'added': addedAt.toIso8601String(),
        'links': links.map((link) => link.source).toList(),
        'provider': providerId,
        'json': rawJson,
        'path': path,
      };

  static StoredProfile fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('У профиля нет идентификатора');
    }

    return StoredProfile(
      id: id,
      name: json['name'] is String ? json['name'] as String : '',
      kind: _kindOf(json['kind']),
      addedAt: _dateOf(json['added']),
      links: parseLinks(_joinSources(json['links'])).links,
      providerId:
          json['provider'] is String ? json['provider'] as String : null,
      rawJson: json['json'] is String ? json['json'] as String : null,
      path: json['path'] is String ? json['path'] as String : null,
    );
  }
}

/// Итог добавления подписки: провайдер сохранён всегда, профиль — только если
/// в ответе нашлись профили. Иначе пользователь видит причину и может повторить.
class SubscriptionAdd {
  const SubscriptionAdd({required this.provider, this.profile, this.error});

  final Provider provider;
  final StoredProfile? profile;
  final String? error;

  bool get ok => profile != null;
}

/// Хранилище профилей и провайдеров. Держит список подключений, активный
/// профиль и кэш подписок, из которого клиент стартует без сети.
class ProfileStore {
  ProfileStore._(this._prefs, this._profiles, this._providers, this._activeId);

  static const _profilesKey = 'profiles.v1';
  static const _providersKey = 'providers.v1';
  static const _activeKey = 'active_profile.v1';

  final SharedPreferences _prefs;
  final List<StoredProfile> _profiles;
  final List<Provider> _providers;
  String? _activeId;

  /// Читает сохранённое. Битые записи пропускаются: одна повреждённая строка
  /// не должна лишать пользователя остальных подключений.
  static Future<ProfileStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return ProfileStore._(
      prefs,
      _readList<StoredProfile>(prefs, _profilesKey, StoredProfile.fromJson),
      _readList<Provider>(prefs, _providersKey, Provider.fromJson),
      prefs.getString(_activeKey),
    );
  }

  List<StoredProfile> get profiles => List.unmodifiable(_profiles);

  List<Provider> get providers => List.unmodifiable(_providers);

  StoredProfile? get active {
    final id = _activeId;
    if (id == null) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Provider? providerOf(String? id) {
    if (id == null) return null;
    for (final provider in _providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  bool get isEmpty => _profiles.isEmpty;

  /// Профили из подписок, которым пора обновиться.
  List<Provider> dueForUpdate(DateTime now) =>
      _providers.where((provider) => provider.needsUpdate(now)).toList();

  /// Добавляет подписку провайдера и сразу её получает.
  Future<SubscriptionAdd> addSubscription(
    String url, {
    String name = '',
    SubscriptionFetcher fetch = fetchSubscription,
    DateTime? now,
  }) async {
    final provider = await addProvider(url, name: name);
    final result = await refresh(
      provider.id,
      fetch: fetch,
      now: now,
    );
    final updated = result.provider;
    if (!result.ok || updated.links.isEmpty) {
      return SubscriptionAdd(
        provider: updated,
        error: result.error ?? 'В ответе провайдера нет ни одного профиля',
      );
    }

    final profile = _profileOfProvider(updated.id);
    if (profile != null) {
      final renewed = profile.copyWith(links: updated.links);
      await _replaceProfile(renewed);
      return SubscriptionAdd(provider: updated, profile: renewed);
    }

    final added = await _add(
      StoredProfile(
        id: _newId('subscription', updated.id),
        name: updated.displayName,
        kind: ProfileKind.subscription,
        addedAt: now ?? DateTime.now(),
        links: updated.links,
        providerId: updated.id,
      ),
    );
    return SubscriptionAdd(provider: updated, profile: added);
  }

  /// Сохраняет провайдера по адресу. Повторное добавление того же адреса
  /// возвращает существующую запись вместе с её кэшем.
  Future<Provider> addProvider(String url, {String name = ''}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Адрес подписки пуст');
    }

    final id = providerIdOf(trimmed);
    final existing = providerOf(id);
    if (existing != null) {
      return name.isEmpty || existing.name == name
          ? existing
          : await _replaceProvider(existing.copyWith(name: name));
    }

    final provider = Provider(id: id, url: trimmed, name: name.trim());
    _providers.add(provider);
    await _saveProviders();
    return provider;
  }

  /// Обновляет подписку и сохраняет результат. Кэш прошлой хорошей версии
  /// остаётся на месте и при сбое, чтобы подключение работало без сети.
  Future<RefreshResult> refresh(
    String providerId, {
    SubscriptionFetcher fetch = fetchSubscription,
    DateTime? now,
  }) async {
    final provider = providerOf(providerId);
    if (provider == null) {
      throw FormatException('Провайдер не найден: $providerId');
    }

    final result = await refreshProvider(
      provider,
      fetch: fetch,
      now: now ?? DateTime.now(),
    );
    await _replaceProvider(result.provider);

    final profile = _profileOfProvider(providerId);
    if (result.ok && profile != null) {
      await _replaceProfile(
        profile.copyWith(links: result.provider.links),
      );
    }
    return result;
  }

  /// Обновляет всё, что подошло по интервалу. Сбой одного провайдера не
  /// мешает остальным.
  Future<List<RefreshResult>> refreshDue({
    SubscriptionFetcher fetch = fetchSubscription,
    DateTime? now,
  }) async {
    final moment = now ?? DateTime.now();
    final results = <RefreshResult>[];
    for (final provider in dueForUpdate(moment)) {
      results.add(await refresh(provider.id, fetch: fetch, now: moment));
    }
    return results;
  }

  Future<StoredProfile> addLinks({
    required String name,
    required Iterable<ShareLink> links,
    DateTime? now,
  }) {
    final parsed = links.toList();
    if (parsed.isEmpty) {
      throw LinkFormatException('Нет ни одной ссылки для профиля');
    }
    return _add(
      StoredProfile(
        id: _newId('links', parsed.map((link) => link.source).join()),
        name: name.trim().isEmpty ? parsed.first.name : name.trim(),
        kind: ProfileKind.links,
        addedAt: now ?? DateTime.now(),
        links: parsed,
      ),
    );
  }

  Future<StoredProfile> addFile(VpnConfig config, {DateTime? now}) => _add(
        StoredProfile(
          id: _newId('file', config.path ?? config.json),
          name: config.name,
          kind: ProfileKind.file,
          addedAt: now ?? DateTime.now(),
          rawJson: config.json,
          path: config.path,
        ),
      );

  Future<void> rename(String id, String name) async {
    final profile = _byId(id);
    if (profile == null) return;
    await _replaceProfile(profile.copyWith(name: name.trim()));
  }

  Future<void> setActive(String id) async {
    if (_byId(id) == null) {
      throw FormatException('Профиль не найден: $id');
    }
    _activeId = id;
    await _prefs.setString(_activeKey, id);
  }

  /// Удаляет профиль и его провайдера, если других профилей от него не осталось.
  Future<bool> remove(String id) async {
    final profile = _byId(id);
    if (profile == null) return false;

    _profiles.remove(profile);
    if (_activeId == id) {
      final next = _profiles.isEmpty ? null : _profiles.first.id;
      _activeId = next;
      if (next == null) {
        await _prefs.remove(_activeKey);
      } else {
        await _prefs.setString(_activeKey, next);
      }
    }

    final providerId = profile.providerId;
    if (providerId != null && _profileOfProvider(providerId) == null) {
      _providers.removeWhere((provider) => provider.id == providerId);
      await _saveProviders();
    }

    await _saveProfiles();
    return true;
  }

  /// Конфиг ядра для активного профиля: из файла пользователя или собранный
  /// в памяти из ссылок.
  VpnConfig activeConfig() {
    final profile = active;
    if (profile == null) {
      throw LinkFormatException('Сначала добавьте подключение');
    }

    if (profile.kind == ProfileKind.file) {
      final json = profile.rawJson;
      if (json == null || json.isEmpty) {
        throw LinkFormatException('Файл «${profile.name}» недоступен');
      }
      return VpnConfig(name: profile.name, json: json, path: profile.path);
    }

    if (profile.links.isEmpty) {
      throw LinkFormatException('В подключении «${profile.name}» нет профилей');
    }
    return VpnConfig(
      name: profile.name,
      json: buildConfigFromLinks(profile.links),
    );
  }

  Future<StoredProfile> _add(StoredProfile profile) async {
    final index = _profiles.indexWhere((item) => item.id == profile.id);
    if (index >= 0) {
      _profiles[index] = profile;
    } else {
      _profiles.add(profile);
    }
    if (_activeId == null) {
      await setActive(profile.id);
    }
    await _saveProfiles();
    return profile;
  }

  Future<void> _replaceProfile(StoredProfile profile) async {
    final index = _profiles.indexWhere((item) => item.id == profile.id);
    if (index < 0) return;
    _profiles[index] = profile;
    await _saveProfiles();
  }

  Future<Provider> _replaceProvider(Provider provider) async {
    final index = _providers.indexWhere((item) => item.id == provider.id);
    if (index >= 0) {
      _providers[index] = provider;
    } else {
      _providers.add(provider);
    }
    await _saveProviders();
    return provider;
  }

  Future<void> _saveProfiles() => _prefs.setString(
        _profilesKey,
        jsonEncode(_profiles.map((profile) => profile.toJson()).toList()),
      );

  Future<void> _saveProviders() => _prefs.setString(
        _providersKey,
        jsonEncode(_providers.map((provider) => provider.toJson()).toList()),
      );

  StoredProfile? _byId(String id) {
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  StoredProfile? _profileOfProvider(String providerId) {
    for (final profile in _profiles) {
      if (profile.providerId == providerId) return profile;
    }
    return null;
  }
}

String _newId(String kind, String seed) =>
    md5.convert(utf8.encode('$kind|$seed')).toString();

ProfileKind _kindOf(Object? raw) {
  for (final kind in ProfileKind.values) {
    if (kind.name == raw) return kind;
  }
  return ProfileKind.links;
}

DateTime _dateOf(Object? raw) =>
    raw is String ? (DateTime.tryParse(raw) ?? DateTime.now()) : DateTime.now();

String _joinSources(Object? raw) {
  if (raw is! List) return '';
  return raw.whereType<String>().join('\n');
}

List<T> _readList<T>(
  SharedPreferences prefs,
  String key,
  T Function(Map<String, dynamic> json) parse,
) {
  final raw = prefs.getString(key);
  if (raw == null || raw.isEmpty) return [];

  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return [];
  }
  if (decoded is! List) return [];

  final items = <T>[];
  for (final entry in decoded) {
    if (entry is! Map<String, dynamic>) continue;
    try {
      items.add(parse(entry));
    } on FormatException {
      // Битая запись пропускается, остальные остаются доступны.
    }
  }
  return items;
}
