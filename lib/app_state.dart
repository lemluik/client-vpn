import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:shared_preferences/shared_preferences.dart';

import 'autostart.dart';
import 'chat_service.dart';
import 'chat_store.dart';
import 'core_stats.dart';
import 'deep_link.dart';
import 'failover.dart';
import 'log_mask.dart';
import 'manual_rules.dart';
import 'per_app_rules.dart';
import 'profile_store.dart';
import 'provider.dart';
import 'reconnect.dart';
import 'region.dart';
import 'routing_presets.dart';
import 'services/service_config.dart';
import 'settings_store.dart';
import 'share_link.dart';
import 'subscription.dart';
import 'temp_config.dart';
import 'traffic.dart';
import 'vpn_config.dart';
import 'vpn_core.dart';

/// Состояние туннеля: пять значений, которые видит пользователь.
///
/// `noLink` отличается от `failure` тем, что рвать пробовался не путь: связи
/// нет совсем (сеть пропала), и показывать ошибку узла было бы неверно.
enum TunnelState { off, connecting, on, failure, noLink }

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

/// Сети, смена которых рвёт установленные соединения ядра.
///
/// `none` и `vpn` в подпись не входят: в первую переподнимать туннель некуда,
/// второе — собственный туннель клиента не должен считаться сменой сети.
const Set<ConnectivityResult> networkTransports = {
  ConnectivityResult.bluetooth,
  ConnectivityResult.ethernet,
  ConnectivityResult.mobile,
  ConnectivityResult.other,
  ConnectivityResult.wifi,
};

/// Сеть в виде строки для сравнения: `'wifi'`, `'mobile'`, `''` — связи нет.
String networkKey(List<ConnectivityResult> networks) {
  final names =
      networks
          .where(networkTransports.contains)
          .map((network) => network.name)
          .toSet()
          .toList()
        ..sort();
  return names.join(',');
}

/// Связка хранилища профилей и ядра для экрана.
///
/// Долгие операции не останавливают отрисовку: экран слушает уведомления и
/// показывает ход работы, кнопки выбора профиля и добавления остаются живыми.
class AppState extends ChangeNotifier {
  AppState(
    this._store,
    this._core, {
    required SettingsStore settings,
    ConfigWriter? configWriter,
    ChatService? chat,
    Autostart? autostart,
    PresetStore? presets,
    RuleStore? ruleStore,
    PerAppStore? perApps,
    AppExclusionsWriter? appExclusions,
    ProbeStore? probes,
    ReconnectPlan? reconnect,
    String languageCode = '',
    Stream<List<ConnectivityResult>>? networks,
    Stream<String>? deepLinks,
    ServiceConfig? serviceConfig,
  }) : _writeConfig =
           configWriter ??
           (Platform.isAndroid ? _passThrough : ensureConfigOnDisk),
       _chat = chat,
       _settings = settings,
       _autostart = autostart ?? const UnsupportedAutostart(),
       _presets = presets,
       _ruleStore = ruleStore,
       _manualRules = ruleStore?.load() ?? const [],
       _perApps = perApps,
       _appExclusions = appExclusions,
       _directApps = perApps?.load() ?? const [],
       _probes = probes,
       _reconnect = reconnect ?? ReconnectPlan(),
       _probeEndpoint = probes?.load() ?? defaultProbeEndpoint,
       _languageCode = languageCode,
       _routingPreset =
           presets?.load(languageCode) ?? defaultPresetFor(languageCode),
       serviceConfig = serviceConfig ?? const ServiceConfig() {
    _logSubscription = _core.logs.listen(_onLog);
    _statusSubscription = _core.statusChanges.listen(_onStatus);
    _networkSubscription = networks?.listen(_onNetworks);
    _deepLinkSubscription = deepLinks?.listen(_onDeepLink);
  }

  static Future<AppState> create() async {
    final prefs = await SharedPreferences.getInstance();
    return AppState(
      await ProfileStore.open(),
      createVpnCore(),
      settings: await SettingsStore.open(),
      autostart: Autostart.platform(),
      chat: ChatService(await ChatStore.open()),
      presets: PresetStore(prefs),
      ruleStore: RuleStore(prefs),
      perApps: PerAppStore(prefs),
      // Приложения «напрямую» умеет только Android: список читает VpnService.
      appExclusions: Platform.isAndroid ? const PerAppChannel().write : null,
      probes: ProbeStore(prefs),
      languageCode: PlatformDispatcher.instance.locale.languageCode,
      networks: Connectivity().onConnectivityChanged,
      deepLinks: deepLinkStream(),
      serviceConfig: await ServiceConfig.load(),
    );
  }

  static const int logLimit = 500;

  /// Окно, за которое события о смене сети успевают закончиться.
  ///
  /// Переход Wi-Fi ↔ LTE приходит не одним событием, а серией, поэтому
  /// переподъём откладывается. Значение 2 с взято как заведомо бо́льшее, чем
  /// разрыв между событиями; живой замер на телефоне ещё не выполнен.
  static const Duration networkSettle = Duration(seconds: 2);

  final ProfileStore _store;
  final VpnCore _core;
  final ConfigWriter _writeConfig;
  final ChatService? _chat;
  final SettingsStore _settings;
  final Autostart _autostart;
  final PresetStore? _presets;

  /// Конфигурация сервиса: имя для надписей и точка контроля пробного ключа.
  /// В открытом клиенте — значения по умолчанию (имя «сервис», пробный ключ
  /// выключен), поэтому клиент остаётся универсальным.
  final ServiceConfig serviceConfig;

  /// Имя сервиса для надписей («Подключить {имя}»). Без конфига — «сервис».
  String get serviceName => serviceConfig.serviceName;

  /// Правила пользователя: хранятся на устройстве, применяются поверх пресета.
  final RuleStore? _ruleStore;
  List<ManualRule> _manualRules;

  /// Приложения, идущие напрямую (R2.3): Android, список читает VpnService.
  final PerAppStore? _perApps;
  final AppExclusionsWriter? _appExclusions;
  List<String> _directApps;
  final ProbeStore? _probes;
  String _probeEndpoint;

  StreamSubscription<String>? _logSubscription;
  StreamSubscription<CoreStatus>? _statusSubscription;
  StreamSubscription<TrafficSnapshot>? _trafficSubscription;
  TrafficSnapshot? _traffic;
  StreamSubscription<List<ConnectivityResult>>? _networkSubscription;
  Timer? _networkTimer;
  Timer? _probeTimer;
  Timer? _subscriptionTimer;
  final ReconnectPlan _reconnect;
  String? _networkKey;
  StreamSubscription<String>? _deepLinkSubscription;

  final List<String> _log = [];
  TunnelState _state = TunnelState.off;
  Failure? _failure;
  bool _busy = false;
  bool _stopping = false;
  bool? _autoStart;

  /// Пользователь хочет туннель поднятым: с этого момента клиент переподключается
  /// сам, без нажатия кнопки.
  bool _userWantsTunnel = false;
  RoutingPreset _routingPreset;

  /// Язык устройства: по нему определяется домашний регион переключателя
  /// «сайты домашнего региона напрямую».
  final String _languageCode;

  /// Чат поддержки, если он выпущен для активной подписки.
  ChatService? get chat => _chat;

  SettingsStore get settings => _settings;

  ThemeChoice get themeChoice => _settings.themeChoice;

  bool get autoConnect => _settings.autoConnect;

  /// Крестик на окне: спросить, свернуть в трей или выйти.
  CloseAction get closeAction => _settings.closeAction;

  /// Платформа без поддержки автозапуска прячет настройку целиком.
  bool get autostartSupported => _autostart.supported;

  bool get autoStart => _autoStart ?? false;

  TunnelState get state => _state;

  Failure? get failure => _failure;

  bool get isBusy => _busy;

  bool get isConnected => _state == TunnelState.on;

  String? get endpoint => _core.endpointLabel;

  /// Трафик туннеля: скорость и итог сессии. На Android этим занимается
  /// уведомление службы, поэтому там всегда null; на десктопе — снимок
  /// раз в секунду, пока туннель поднят.
  TrafficSnapshot? get traffic => _traffic;

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

  /// Выбранный пресет маршрутизации «напрямую».
  RoutingPreset get routingPreset => _routingPreset;

  /// Точка проб наблюдателя (У-3): нейтральная по умолчанию, значение
  /// локальное и никуда, кроме ядра, не отправляется.
  String get probeEndpoint => _probeEndpoint;

  /// Меняет точку проб. Возвращает текст ошибки или null; поднятый туннель
  /// перезапускает экран — конфиг с новой точкой читается только при сборке.
  Future<String?> setProbeEndpoint(String value) async {
    final error = probeEndpointError(value);
    if (error != null) return error;
    final endpoint = value.trim();
    if (endpoint == _probeEndpoint) return null;
    _probeEndpoint = endpoint;
    await _probes?.save(endpoint);
    notifyListeners();
    return null;
  }

  /// Меняет пресет и запоминает выбор. Поднятый туннель перезапускает экран:
  /// правила читаются при сборке конфига, поэтому смена пути рвёт соединения.
  Future<void> setRoutingPreset(String key) async {
    final preset = presetByKey(key);
    if (preset.key == _routingPreset.key) return;
    _routingPreset = preset;
    await _presets?.save(key);
    _failure = null;
    notifyListeners();
  }

  /// Пресет домашнего региона: тот, что подходит языку устройства.
  RoutingPreset get homePreset => defaultPresetFor(_languageCode);

  /// Есть ли у домашнего региона доменные зоны: без них переключателю нечего
  /// включать, и интерфейс прячет пункт.
  bool get homeRegionKnown => homePreset.hasHomeDomains;

  /// Включено ли «сайты домашнего региона напрямую».
  ///
  /// Это не отдельный флаг: переключатель и список-замена на экране настроек
  /// управляют тем же выбранным пресетом (`routing.preset.v1`). Два хранимых
  /// значения неизбежно разошлись бы, и пользователь получил бы экран, который
  /// показывает не то, что реально ушло в ядро.
  bool get homeRegionDirect =>
      !_routingPreset.isOff && _routingPreset.hasHomeDomains;

  /// Включает или выключает правила домашнего региона.
  Future<void> setHomeRegionDirect(bool value) async {
    if (value == homeRegionDirect) return;
    await setRoutingPreset(
      value
          ? (_routingPreset.hasHomeDomains
                ? _routingPreset.key
                : homePreset.key)
          : offPreset.key,
    );
  }

  /// Адреса-исключения, которые идут мимо домашнего региона напрямую.
  List<String> get splitDirectHosts =>
      ManualRule.splitHosts(_manualRules, ManualRule.splitDirectId);

  /// Адреса-исключения, которые возвращаются в туннель.
  List<String> get splitTunnelHosts =>
      ManualRule.splitHosts(_manualRules, ManualRule.splitTunnelId);

  /// Заменяет списки исключений, сохраняя остальные правила пользователя.
  ///
  /// Названия правил приходят из интерфейса: правило — данные, а подпись на
  /// нём — строка, и она обязана быть переведена.
  Future<void> setSplitHosts({
    required List<String> direct,
    required List<String> tunnel,
    required String directTitle,
    required String tunnelTitle,
  }) => setManualRules(
    ManualRule.withSplitHosts(
      _manualRules,
      direct: direct,
      tunnel: tunnel,
      directTitle: directTitle,
      tunnelTitle: tunnelTitle,
    ),
  );

  /// Правила пользователя в порядке применения.
  List<ManualRule> get manualRules => List.unmodifiable(_manualRules);

  /// Заменяет список правил и запоминает его.
  ///
  /// Поднятый туннель перезапускает экран — по той же причине, что и смена
  /// пресета: правила читаются при сборке конфига.
  Future<void> setManualRules(List<ManualRule> rules) async {
    _manualRules = List.of(rules);
    await _ruleStore?.save(_manualRules);
    _failure = null;
    notifyListeners();
  }

  /// Пакеты приложений, которые идут напрямую, мимо туннеля (R2.3).
  List<String> get directApps => List.unmodifiable(_directApps);

  /// Меняет список приложений «напрямую» и запоминает его.
  ///
  /// Нативной части список передаётся при подключении (см. [connect]): там,
  /// где его и читает `VpnService`. Работает только на Android — на десктопе
  /// ядро условия по приложению не поддерживает, и интерфейс кнопки не
  /// показывает.
  Future<void> setDirectApps(List<String> packages) async {
    _directApps = List.of(packages);
    await _perApps?.save(_directApps);
    notifyListeners();
  }

  List<String> get log => List.unmodifiable(_log);

  bool get canConnect =>
      _state != TunnelState.connecting && (_store.active?.canStart ?? false);

  /// Журнал в виде, пригодном для публичного обращения: без адресов и ключей.
  String exportLog() => maskLog(_log);

  /// Откатывает состояние после аварийного завершения и подтягивает подписки,
  /// которым пора обновиться.
  ///
  /// Вызывается при каждом старте приложения: и снятие системного прокси,
  /// оставшегося после внешнего убийства процесса, и вопрос сервису Android
  /// («туннель поднят?»), и подписки по интервалу.
  Future<void> recover() async {
    await _core.recoverAfterCrash();
    await refreshDue();
    await connectFromShell();
  }

  /// Ставит метку свежести на сохранённый конфиг туннеля: пока она стоит,
  /// плитка шторки поднимает туннель без открытия приложения.
  Future<void> markTunnelFresh() async {
    if (!Platform.isAndroid) return;
    try {
      await _core.markTunnelFresh();
    } on MissingPluginException {
      // Старая нативная часть: метку поставить некому, плитка пойдёт путём Б.
    }
  }

  /// Путь Б плитки: приложение открыто тапом по плитке, подключается само.
  Future<void> connectFromShell() async {
    if (!Platform.isAndroid) return;
    final bool pending;
    try {
      pending = await _core.takePendingConnect();
    } on MissingPluginException {
      return;
    }
    if (!pending ||
        _state == TunnelState.on ||
        _state == TunnelState.connecting) {
      return;
    }
    _addLog('Подключение по плитке шторки');
    await connect();
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

  Future<void> setTheme(ThemeChoice value) async {
    await _settings.setTheme(value);
    notifyListeners();
  }

  /// Запомнить или передумать, что делать с крестиком на окне.
  Future<void> setCloseAction(CloseAction value) async {
    await _settings.setCloseAction(value);
    notifyListeners();
  }

  Future<void> setAutoConnect(bool value) async {
    await _settings.setAutoConnect(value);
    notifyListeners();
  }

  /// Флаг автозапуска принадлежит системе и его правят не только отсюда
  /// (regedit, диспетчер задач, настройки Android), поэтому значение
  /// перечитывается, а не хранится в настройках.
  Future<void> refreshAutostart() async {
    if (!_autostart.supported) return;
    _autoStart = await _autostart.isOn();
    notifyListeners();
  }

  Future<void> setAutoStart(bool value) async {
    await _autostart.set(value);
    await refreshAutostart();
  }

  /// Автоподключение при запуске: поднимаем последний успешный профиль,
  /// если он ещё жив. Отказ системы (запрос согласия на Android) оставляет
  /// приложение подключённым к кнопке — пользователь нажмёт сам.
  Future<void> autoConnectOnLaunch() async {
    final id = _settings.lastProfileId;
    if (!_settings.autoConnect || id == null || _state != TunnelState.off) {
      return;
    }

    StoredProfile? profile;
    for (final candidate in _store.profiles) {
      if (candidate.id == id && candidate.canStart) {
        profile = candidate;
        break;
      }
    }
    if (profile == null) return;

    await select(id);
    await connect();
  }

  Future<void> connect() async {
    if (_state == TunnelState.connecting) return;

    _failure = null;
    _state = TunnelState.connecting;
    _userWantsTunnel = true;
    notifyListeners();

    try {
      final config = await _writeConfig(
        _store.activeConfig(
          rules: _routingPreset.rulesWith(_manualRules),
          probeEndpoint: _probeEndpoint,
        ),
      );
      await _core.validate(config);
      // Список приложений «напрямую» пишется перед каждым поднятием туннеля:
      // VpnService читает файл при старте, и правка после подключения не
      // требует, чтобы пользователь помнил про сохранение заранее.
      await _appExclusions?.call(_directApps);
      await _core.start(config);
      await markTunnelFresh();
      _state = TunnelState.on;
      _reconnect.reset();
      _stopReconnectTimers();
      final profile = _store.active;
      if (profile != null) await _settings.rememberProfile(profile.id);
      _addLog('Подключено: ${_activeLabel()}');
    } catch (error) {
      _state = TunnelState.failure;
      _failure = failureOf(error);
      _addLog('[ERR] ${_failure!.message}');
      _armReconnect();
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _userWantsTunnel = false;
    _reconnect.reset();
    _stopReconnectTimers();
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
    final providerId = _store.providerOfProfile(id);
    await _store.remove(id);
    await _settings.forgetProfile(id);
    // Данные чата принадлежат записи провайдера: не стало провайдера —
    // не стало сессии, курсора, очереди и токена.
    if (providerId != null && _store.providerOf(providerId) == null) {
      await _chat?.forget(providerId);
    }
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

  /// Реакция на событие о сети: `'wifi' → 'mobile'` при поднятом туннеле
  /// откладывает переподъём, а серия событий схлопывается в один.
  void _onNetworks(List<ConnectivityResult> networks) {
    final key = networkKey(networks);
    // Первое событие только задаёт отправную точку: до него состояние сети
    // неизвестно, и переподнимать туннель по нему было бы ошибкой.
    if (_networkKey == null) {
      _networkKey = key;
      return;
    }
    if (key == _networkKey) return;
    _networkKey = key;
    if (key.isEmpty) {
      // Сети нет совсем: это «нет связи» (МК-5), а не сбой узла, поэтому
      // ошибку пути не показываем, но переподключение уже стоит в очереди.
      if (_state == TunnelState.on ||
          _state == TunnelState.connecting ||
          _state == TunnelState.failure) {
        _state = TunnelState.noLink;
        _failure = null;
        _armReconnect();
        notifyListeners();
      }
      return;
    }
    if (_state == TunnelState.noLink) {
      if (!_userWantsTunnel || _busy || _stopping) return;
      // Сеть вернулась — подымаемся сразу, не дожидаясь очереди проб.
      _networkTimer?.cancel();
      _networkTimer = Timer(networkSettle, _raiseAfterOutage);
      return;
    }
    if (_state != TunnelState.on || _busy || _stopping) return;
    _networkTimer?.cancel();
    _networkTimer = Timer(networkSettle, _raiseTunnelOnNewNetwork);
  }

  /// Подъём туннеля после того, как связь появилась снова (МК-5).
  Future<void> _raiseAfterOutage() async {
    if (!_userWantsTunnel || _state == TunnelState.on || _busy || _stopping) {
      return;
    }
    _addLog('Сеть появилась — туннель поднимается заново');
    await disconnect();
    await connect();
  }

  Future<void> _raiseTunnelOnNewNetwork() async {
    if (_state != TunnelState.on || _busy || _stopping) return;
    _addLog('Сеть сменилась — туннель поднимается заново');
    await disconnect();
    await connect();
  }

  /// Шаг, который пользователь видит сам: сколько попыток переподключения
  /// использовано из лестницы 1–5–30 минут.
  int get reconnectStep => _reconnect.step;

  /// Живёт ли ещё план переподключения.
  bool get isReconnecting =>
      _probeTimer?.isActive == true || _subscriptionTimer?.isActive == true;

  /// Ставит в очередь переподключение (МК-5): проба туннеля раз в 30 секунд
  /// плюс перечитывание подписки по паузам 1–5–30 минут.
  void _armReconnect() {
    if (!_userWantsTunnel || _stopping) return;
    _probeTimer?.cancel();
    _probeTimer = Timer(_reconnect.probeInterval, _probeLink);
    if (_reconnect.exhausted || (_subscriptionTimer?.isActive ?? false)) return;
    _subscriptionTimer?.cancel();
    _subscriptionTimer = Timer(_reconnect.takePause(), _rereadSubscription);
  }

  Future<void> _probeLink() async {
    if (!_userWantsTunnel || _busy || _stopping) return;
    if (_state == TunnelState.noLink) {
      // Сети нет совсем: туннель поднимает возврат связи, а не проба.
      // Очередь держим на случай, если поток сети смолчит.
      _armReconnect();
      return;
    }
    if (_state == TunnelState.on) return;
    _addLog('Проба связи: подключаемся снова');
    await connect();
  }

  /// Пауза подписки: перечитать подписку и, если туннель ещё лежит, поднять
  /// его. Успешный подъём сам гасит очередь (см. connect), поэтому повторное
  /// вооружение здесь не нужно.
  Future<void> _rereadSubscription() async {
    if (!_userWantsTunnel || _busy || _stopping) return;
    _addLog('Перечитываем подписку после сбоя');
    await refreshDue();
    if (_state == TunnelState.on || _state == TunnelState.noLink) return;
    await connect();
  }

  void _stopReconnectTimers() {
    _probeTimer?.cancel();
    _subscriptionTimer?.cancel();
    _probeTimer = null;
    _subscriptionTimer = null;
  }

  /// Тап по ссылке подключения вне приложения: окно открывается уже с новым
  /// профилем, поэтому экран в этом не участвует и подтверждения не просит.
  void _onDeepLink(String link) => unawaited(_addFromDeepLink(link));

  Future<void> _addFromDeepLink(String link) async {
    final reason = await addFromText(link);
    // Ссылка держит ключ узла, а причина отказа повторяет саму строку:
    // в журнал она попадает только через маскирование.
    _addLog(
      reason == null
          ? 'Подключение добавлено по ссылке'
          : maskSecrets('Ссылка не добавлена: $reason'),
    );
  }

  void _onStatus(CoreStatus status) {
    if (status.running) {
      // Подъём из шторки — тоже намерение пользователя: без него переподъём
      // при смене сети (позиция 27) и подъём после «нет связи» (МК-5) не
      // работают, обе ветки читают этот флаг.
      _userWantsTunnel = true;
      _state = TunnelState.on;
      _failure = null;
      _startTrafficWatch();
    } else if (_stopping || _state != TunnelState.on) {
      _stopTrafficWatch();
      _state = TunnelState.off;
      if (status.byShell) _userWantsTunnel = false;
    } else if (status.byShell) {
      // Снято плиткой: пользователь отключился сам, это не сбой, и лестница
      // переподключения не должна поднимать туннель обратно.
      _stopping = true;
      _reconnect.reset();
      _stopReconnectTimers();
      _userWantsTunnel = false;
      _state = TunnelState.off;
      _failure = null;
      _stopping = false;
      _addLog('Отключено из шторки');
    } else {
      _stopTrafficWatch();
      // Ядро остановилось само: для пользователя это сбой, а не отключение.
      _state = TunnelState.failure;
      _failure = const Failure(
        'Соединение прервано',
        'Подключитесь снова или обновите подписку',
      );
      _addLog('[ERR] Соединение прервано');
      _armReconnect();
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

  /// Секундный опрос счётчиков ядра — зеркало таймера TunnelService.kt.
  /// На Android и без поднятого API статистики опрос не начинается: там
  /// трафик показывает уведомление службы, а тестовые ядра API не поднимают.
  void _startTrafficWatch() {
    _stopTrafficWatch();
    if (Platform.isAndroid || CoreStats.apiPort == null) return;
    _trafficSubscription = TrafficPoller().watch().listen((snapshot) {
      _traffic = snapshot;
      notifyListeners();
    });
  }

  void _stopTrafficWatch() {
    _trafficSubscription?.cancel();
    _trafficSubscription = null;
    _traffic = null;
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
    _stopTrafficWatch();
    _networkTimer?.cancel();
    _networkSubscription?.cancel();
    _stopReconnectTimers();
    _deepLinkSubscription?.cancel();
    _chat?.dispose();
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
