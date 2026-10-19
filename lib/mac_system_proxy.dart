import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Запуск `networksetup`: подменяется в проверке, чтобы тест не трогал
/// настройки сети машины.
typedef NetworkSetupRunner = Future<ProcessResult> Function(List<String> args);

Future<ProcessResult> _runNetworkSetup(List<String> args) =>
    Process.run('/usr/sbin/networksetup', args);

/// Настройка одного вида прокси у одной сетевой службы, как её отдаёт
/// `networksetup -getwebproxy` и соседние команды.
class MacProxyEntry {
  const MacProxyEntry({
    required this.enabled,
    required this.server,
    required this.port,
  });

  final bool enabled;
  final String server;
  final int port;

  static const off = MacProxyEntry(enabled: false, server: '', port: 0);

  /// Разбор вывода вида:
  /// ```
  /// Enabled: Yes
  /// Server: 127.0.0.1
  /// Port: 10808
  /// Authenticated Proxy Enabled: 0
  /// ```
  static MacProxyEntry parse(String output) {
    String? field(String name) => RegExp(
      '^$name: ?(.*)\$',
      multiLine: true,
    ).firstMatch(output)?.group(1)?.trim();

    return MacProxyEntry(
      enabled: field('Enabled')?.toLowerCase() == 'yes',
      server: field('Server') ?? '',
      port: int.tryParse(field('Port') ?? '') ?? 0,
    );
  }

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'server': server,
    'port': port,
  };

  static MacProxyEntry fromJson(Object? json) {
    if (json is! Map) return off;
    return MacProxyEntry(
      enabled: json['enabled'] == true,
      server: json['server'] is String ? json['server'] as String : '',
      port: json['port'] is int ? json['port'] as int : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MacProxyEntry &&
      other.enabled == enabled &&
      other.server == server &&
      other.port == port;

  @override
  int get hashCode => Object.hash(enabled, server, port);
}

/// Снимок прокси одной сетевой службы до нашего включения.
class MacServiceSnapshot {
  const MacServiceSnapshot({
    required this.web,
    required this.secureWeb,
    required this.socks,
    required this.bypass,
  });

  final MacProxyEntry web;
  final MacProxyEntry secureWeb;
  final MacProxyEntry socks;

  /// Пустой список — исключений нет («There aren't any bypass domains»).
  final List<String> bypass;

  Map<String, Object> toJson() => {
    'web': web.toJson(),
    'secureWeb': secureWeb.toJson(),
    'socks': socks.toJson(),
    'bypass': bypass,
  };

  static MacServiceSnapshot fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final bypass = map['bypass'];
    return MacServiceSnapshot(
      web: MacProxyEntry.fromJson(map['web']),
      secureWeb: MacProxyEntry.fromJson(map['secureWeb']),
      socks: MacProxyEntry.fromJson(map['socks']),
      bypass: bypass is List ? bypass.whereType<String>().toList() : const [],
    );
  }
}

/// Системный прокси macOS через `networksetup`.
///
/// Прокси на macOS задаётся отдельно для каждой сетевой службы (Wi-Fi,
/// Ethernet, USB-модем…). Включаем на всех включённых службах: при смене
/// сети трафик не должен уйти мимо ядра через службу, о которой мы забыли.
/// Исходные настройки каждой службы сохраняются и возвращаются как были.
///
/// Логика та же, что у реестра Windows: [lockLeak] держит прокси на мёртвом
/// порту после аварии ядра, [cleanupAfterCrash] при старте снимает только
/// то, что включали мы сами.
class MacSystemProxy {
  MacSystemProxy({NetworkSetupRunner? run}) : _run = run ?? _runNetworkSetup;

  final NetworkSetupRunner _run;

  static const _savedKey = 'proxy.mac.saved';
  static const _oursKey = 'proxy.ours';

  /// Локальные адреса мимо прокси: иначе браузер проксирует и `localhost`,
  /// и адреса локальной сети.
  static const localBypass = [
    'localhost',
    '127.0.0.1',
    '::1',
    '*.local',
    '169.254/16',
  ];

  /// Метка «наш прокси» в настройках: `http 127.0.0.1:10808` или
  /// `socks 127.0.0.1:10808`. По ней после аварии отличаем свой прокси от
  /// чужого (Proxyman, Charles, Clash и т.п.).
  static String oursLabel(String host, int port, {required bool socks}) =>
      '${socks ? 'socks' : 'http'} $host:$port';

  /// Разбор `networksetup -listallnetworkservices`: первая строка —
  /// пояснение, выключенные службы помечены `*`.
  static List<String> parseServices(String output) => const LineSplitter()
      .convert(output)
      .skip(1)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('*'))
      .toList();

  /// Разбор `networksetup -getproxybypassdomains`: строка-пояснение
  /// «There aren't any bypass domains…» означает пустой список.
  static List<String> parseBypass(String output) => const LineSplitter()
      .convert(output)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('There aren'))
      .toList();

  /// Исключения дописываются к текущим, а не заменяются: набор пользователя
  /// возвращается при отключении в том же виде.
  static List<String> withLocalBypass(List<String> current) => [
    ...current,
    ...localBypass.where(
      (entry) => !current.any((c) => c.toLowerCase() == entry.toLowerCase()),
    ),
  ];

  Future<List<String>> services() async {
    final result = await _run(['-listallnetworkservices']);
    if (result.exitCode != 0) {
      throw Exception('networksetup не отдал список служб: ${result.stderr}');
    }
    return parseServices('${result.stdout}');
  }

  Future<MacServiceSnapshot> snapshot(String service) async {
    Future<MacProxyEntry> read(String command) async {
      final result = await _run([command, service]);
      return result.exitCode == 0
          ? MacProxyEntry.parse('${result.stdout}')
          : MacProxyEntry.off;
    }

    final bypass = await _run(['-getproxybypassdomains', service]);
    return MacServiceSnapshot(
      web: await read('-getwebproxy'),
      secureWeb: await read('-getsecurewebproxy'),
      socks: await read('-getsocksfirewallproxy'),
      bypass: bypass.exitCode == 0 ? parseBypass('${bypass.stdout}') : const [],
    );
  }

  Future<void> enable(String host, int port, {bool socks = false}) async {
    final list = await services();
    if (list.isEmpty) {
      throw Exception('Нет включённых сетевых служб — прокси ставить некуда.');
    }

    final prefs = await SharedPreferences.getInstance();
    final saved = _readSaved(prefs);
    // Снимок пишется только при первом включении: повторный старт после
    // аварии не должен затереть настройки пользователя нашими.
    for (final service in list) {
      saved[service] ??= await snapshot(service);
    }
    await prefs.setString(
      _savedKey,
      jsonEncode(saved.map((k, v) => MapEntry(k, v.toJson()))),
    );
    await prefs.setString(_oursKey, oursLabel(host, port, socks: socks));

    for (final service in list) {
      await _apply(
        service,
        host,
        port,
        socks: socks,
        bypass: saved[service]!.bypass,
      );
    }
  }

  Future<void> _apply(
    String service,
    String host,
    int port, {
    required bool socks,
    required List<String> bypass,
  }) async {
    if (socks) {
      await _set(['-setsocksfirewallproxy', service, host, '$port']);
      await _set(['-setsocksfirewallproxystate', service, 'on']);
      await _set(['-setwebproxystate', service, 'off']);
      await _set(['-setsecurewebproxystate', service, 'off']);
    } else {
      await _set(['-setwebproxy', service, host, '$port']);
      await _set(['-setsecurewebproxy', service, host, '$port']);
      await _set(['-setwebproxystate', service, 'on']);
      await _set(['-setsecurewebproxystate', service, 'on']);
      await _set(['-setsocksfirewallproxystate', service, 'off']);
    }
    await _setBypass(service, withLocalBypass(bypass));
  }

  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_oursKey) == null) return;

    final saved = _readSaved(prefs);
    final present = (await services()).toSet();
    for (final MapEntry(key: service, value: snap) in saved.entries) {
      // Служба могла пропасть (отключили USB-модем): вернуть некуда.
      if (!present.contains(service)) continue;
      await _restore(service, snap);
    }

    await prefs.remove(_oursKey);
    await prefs.remove(_savedKey);
  }

  Future<void> _restore(String service, MacServiceSnapshot snap) async {
    // Адрес возвращается и пустым: иначе после отключения в настройках
    // остался бы наш 127.0.0.1 (выключенный, но видный пользователю).
    // `-set…proxy` попутно включает прокси, поэтому состояние — вторым шагом.
    Future<void> put(String set, String state, MacProxyEntry entry) async {
      final port = entry.server.isEmpty ? '' : '${entry.port}';
      await _set([set, service, entry.server, port]);
      await _set([state, service, entry.enabled ? 'on' : 'off']);
    }

    await put('-setwebproxy', '-setwebproxystate', snap.web);
    await put('-setsecurewebproxy', '-setsecurewebproxystate', snap.secureWeb);
    await put(
      '-setsocksfirewallproxy',
      '-setsocksfirewallproxystate',
      snap.socks,
    );
    await _setBypass(service, snap.bypass);
  }

  /// Килл-свитч: при падении ядра прокси остаётся включённым на мёртвый
  /// порт, и приложения, слушающие системный прокси, получают отказ вместо
  /// прямого выхода в сеть.
  Future<void> lockLeak() async {
    final prefs = await SharedPreferences.getInstance();
    final ours = _parseOurs(prefs.getString(_oursKey));
    if (ours == null) return;

    final saved = _readSaved(prefs);
    for (final service in await services()) {
      await _apply(
        service,
        ours.host,
        ours.port,
        socks: ours.socks,
        bypass: saved[service]?.bypass ?? const [],
      );
    }
  }

  /// Откатывает прокси, оставшийся включённым после аварийного завершения.
  /// Трогает настройки, только если хотя бы на одной службе стоит именно
  /// наш прокси: иначе пользователь уже поставил свой, и ломать его нельзя.
  Future<void> cleanupAfterCrash() async {
    final prefs = await SharedPreferences.getInstance();
    final ours = _parseOurs(prefs.getString(_oursKey));
    if (ours == null) return;

    for (final service in await services()) {
      final snap = await snapshot(service);
      final entry = ours.socks ? snap.socks : snap.web;
      if (entry.enabled &&
          entry.server == ours.host &&
          entry.port == ours.port) {
        await disable();
        return;
      }
    }

    await prefs.remove(_oursKey);
    await prefs.remove(_savedKey);
  }

  Map<String, MacServiceSnapshot> _readSaved(SharedPreferences prefs) {
    final raw = prefs.getString(_savedKey);
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String) key: MacServiceSnapshot.fromJson(value),
      };
    } on FormatException {
      return {};
    }
  }

  static ({String host, int port, bool socks})? _parseOurs(String? label) {
    if (label == null) return null;
    final match = RegExp(r'^(http|socks) (.+):(\d+)$').firstMatch(label);
    if (match == null) return null;
    return (
      host: match.group(2)!,
      port: int.parse(match.group(3)!),
      socks: match.group(1) == 'socks',
    );
  }

  Future<void> _setBypass(String service, List<String> domains) => _set([
    '-setproxybypassdomains',
    service,
    ...(domains.isEmpty ? ['Empty'] : domains),
  ]);

  Future<void> _set(List<String> args) async {
    final result = await _run(args);
    // networksetup пишет ошибки в stdout и не всегда меняет код возврата.
    final out = '${result.stdout}${result.stderr}'.trim();
    if (result.exitCode != 0 || out.contains('Error') || out.contains('** ')) {
      throw Exception('networksetup ${args.first} не выполнен: $out');
    }
  }
}
