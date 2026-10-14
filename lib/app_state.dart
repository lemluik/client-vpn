import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log_mask.dart';
import 'profile_store.dart';
import 'provider.dart';
import 'region.dart';
import 'share_link.dart';
import 'subscription.dart';
import 'temp_config.dart';
import 'vpn_config.dart';
import 'vpn_core.dart';

/// Состояние туннеля: четыре значения, которые видит пользователь.
enum TunnelState { off, connecting, on, failure }

/// Подготовка конфига для ядра: на десктопе ядро читает его только с диска.
typedef ConfigWriter = Future<VpnConfig> Function(VpnConfig config);

Future<VpnConfig> _passThrough(VpnConfig config) async => config;

/// Ошибка вместе с готовым действием — текст ядра сам по себе не подсказывает,
/// что делать дальше.
class Failure {
  const Failure(this.message, this.action);

  final String message;
  final String action;
}

/// Связка хранилища профилей и ядра для экрана.
///
/// Долгие операции не останавливают отрисовку: экран слушает уведомления и
/// показывает ход работы, кнопки выбора профиля и добавления остаются живыми.
class AppState extends ChangeNotifier {
  AppState(this._store, this._core, {ConfigWriter? configWriter})
      : _writeConfig = configWriter ??
            (Platform.isAndroid ? _passThrough : ensureConfigOnDisk) {
    _logSubscription = _core.logs.listen(_onLog);
    _statusSubscription = _core.statusChanges.listen(_onStatus);
  }

  static Future<AppState> create() async =>
      AppState(await ProfileStore.open(), createVpnCore());

  static const int logLimit = 500;

  final ProfileStore _store;
  final VpnCore _core;
  final ConfigWriter _writeConfig;

  StreamSubscription<String>? _logSubscription;
  StreamSubscription<bool>? _statusSubscription;

  final List<String> _log = [];
  TunnelState _state = TunnelState.off;
  Failure? _failure;
  bool _busy = false;
  bool _stopping = false;

  TunnelState get state => _state;

  Failure? get failure => _failure;

  bool get isBusy => _busy;

  bool get isConnected => _state == TunnelState.on;

  String? get endpoint => _core.endpointLabel;

  List<StoredProfile> get profiles => _store.profiles;

  StoredProfile? get activeProfile => _store.active;

  Provider? get activeProvider => _store.providerOf(_store.active?.providerId);

  /// Регионы выхода активного подключения. Два и больше — пользователь выбирает.
  List<Region> get regions => _store.activeRegions;

  /// Действующий регион: выбранный, а если он пропал из подписки — первый.
  Region? get activeRegion {
    final list = regions;
    if (list.isEmpty) return null;
    return regionByKey(list, _store.active?.region) ?? list.first;
  }

  List<Provider> get providers => _store.providers;

  List<String> get log => List.unmodifiable(_log);

  bool get canConnect =>
      _state != TunnelState.connecting && (_store.active?.canStart ?? false);

  /// Журнал в виде, пригодном для публичного обращения: без адресов и ключей.
  String exportLog() => maskLog(_log);

  /// Откатывает состояние после аварийного завершения и подтягивает подписки,
  /// которым пора обновиться.
  Future<void> recover() async {
    if (!Platform.isAndroid) {
      await _core.recoverAfterCrash();
    }
    await refreshDue();
  }

  Future<void> select(String id) async {
    await _store.setActive(id);
    _failure = null;
    notifyListeners();
  }

  /// Меняет регион выхода. Туннель перезапускает экран: смена пути рвёт
  /// установленные соединения, поэтому её подтверждает пользователь.
  Future<void> selectRegion(String key) async {
    final profile = _store.active;
    if (profile == null) return;
    await _store.setRegion(profile.id, key);
    _failure = null;
    notifyListeners();
  }

  Future<void> connect() async {
    if (_state == TunnelState.connecting) return;

    _failure = null;
    _state = TunnelState.connecting;
    notifyListeners();

    try {
      final config = await _writeConfig(_store.activeConfig());
      await _core.validate(config);
      await _core.start(config);
      _state = TunnelState.on;
      _addLog('Подключено: ${_activeLabel()}');
    } catch (error) {
      _state = TunnelState.failure;
      _failure = failureOf(error);
      _addLog('[ERR] ${_failure!.message}');
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _stopping = true;
    try {
      await _core.stop();
      _state = TunnelState.off;
      _failure = null;
      _addLog('Отключено');
    } finally {
      _stopping = false;
    }
    notifyListeners();
  }

  /// Принимает ссылку, список ссылок и подписку в base64 — всё одним полем.
  /// Возвращает текст ошибки или null.
  Future<String?> addFromText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'Вставьте ссылку или подписку';

    final subscription = parseSubscription(trimmed);
    if (subscription.isEmpty) {
      return _skipReason(subscription);
    }

    final profile = await _store.addLinks(
      name: subscription.title ?? '',
      links: subscription.links,
    );
    await _store.setActive(profile.id);
    _addLog('Добавлено профилей: ${subscription.links.length}');
    if (subscription.skipped.isNotEmpty) {
      _addLog('Пропущено строк: ${subscription.skipped.length}');
    }
    notifyListeners();
    return null;
  }

  /// Добавляет подписку по адресу и сразу её получает.
  Future<String?> addSubscription(String url) async {
    if (url.trim().isEmpty) return 'Введите адрес подписки';

    _busy = true;
    notifyListeners();
    try {
      final added = await _store.addSubscription(url.trim());
      if (!added.ok) {
        _addLog('[ERR] ${added.error}');
        return added.error;
      }
      await _store.setActive(added.profile!.id);
      _addLog('Подписка добавлена: ${added.profile!.name}');
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<String?> addFile() async {
    final config = await pickVpnConfig();
    if (config == null) return null;

    final profile = await _store.addFile(config);
    await _store.setActive(profile.id);
    _addLog('Добавлен файл: ${profile.name}');
    notifyListeners();
    return null;
  }

  Future<void> rename(String id, String name) async {
    await _store.rename(id, name);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    if (_state == TunnelState.on && _store.active?.id == id) {
      await disconnect();
    }
    await _store.remove(id);
    if (_store.active == null) _failure = null;
    notifyListeners();
  }

  /// Обновляет подписку активного профиля, не дожидаясь интервала.
  Future<String?> refreshActive() async {
    final provider = activeProvider;
    if (provider == null) return 'Это подключение не из подписки';

    _busy = true;
    notifyListeners();
    try {
      final result = await _store.refresh(provider.id);
      if (!result.ok) {
        _addLog('[ERR] ${result.error}');
        return result.error;
      }
      _addLog('Подписка обновлена: ${result.provider.links.length} профилей');
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Обновляет подписки, которым пора по интервалу провайдера.
  Future<String?> refreshDue() async {
    _busy = true;
    notifyListeners();
    try {
      final results = await _store.refreshDue();
      final failures = results.where((result) => !result.ok).toList();
      if (failures.isNotEmpty && failures.length == results.length) {
        return failures.first.error;
      }
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _onLog(String line) => _addLog(line);

  void _onStatus(bool running) {
    if (running) {
      _state = TunnelState.on;
      _failure = null;
    } else if (_stopping || _state != TunnelState.on) {
      _state = TunnelState.off;
    } else {
      // Ядро остановилось само: для пользователя это сбой, а не отключение.
      _state = TunnelState.failure;
      _failure = const Failure(
        'Соединение прервано',
        'Подключитесь снова: профиль сохранён',
      );
      _addLog('[ERR] Соединение прервано');
    }
    notifyListeners();
  }

  /// Имя подключения вместе с регионом, если провайдер их различает.
  String _activeLabel() {
    final name = _store.active?.name ?? '';
    final region = activeRegion;
    return regions.length > 1 && region != null
        ? '$name · ${region.label}'
        : name;
  }

  void _addLog(String line) {
    _log.add(line);
    if (_log.length > logLimit) {
      _log.removeRange(0, _log.length - logLimit);
    }
    notifyListeners();
  }

  String _skipReason(Subscription subscription) {
    if (subscription.skipped.isEmpty) return 'Не найдено ни одного профиля';
    final first = subscription.skipped.first;
    return 'Строка ${first.line}: ${first.reason}';
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _statusSubscription?.cancel();
    unawaited(_core.dispose());
    unawaited(clearWorkingDirectory());
    super.dispose();
  }
}

/// Превращает исключение в пару «что случилось — что делать».
Failure failureOf(Object error) {
  final text = _textOf(error);

  if (text.contains('не найден')) {
    return const Failure(
      'Ядро не найдено',
      'Скачайте ядро: bash scripts/download_xray.sh',
    );
  }
  if (text.contains('целостности')) {
    return const Failure(
      'Проверка целостности ядра не пройдена',
      'Перекачайте ядро: bash scripts/download_xray.sh',
    );
  }
  if (text.contains('нет inbound')) {
    return const Failure(
      'В конфиге нет локальной точки входа',
      'Добавьте профиль из ссылки или inbound http либо socks',
    );
  }
  if (text.contains('уже запущен')) {
    return const Failure(
      'Ядро уже работает',
      'Отключитесь и подключитесь снова',
    );
  }
  return Failure(text, 'Подключитесь снова или выберите другой профиль');
}

String _textOf(Object error) {
  var text = error is LinkFormatException ? error.message : error.toString();
  if (text.startsWith('Exception: ')) {
    text = text.substring('Exception: '.length);
  }
  final lines = text.split('\n');
  final first = lines.first.trim();
  return first.length > 200 ? '${first.substring(0, 200)}…' : first;
}
