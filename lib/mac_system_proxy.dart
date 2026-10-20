import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Runs `networksetup`: replaced in tests so they do not touch the machine's
/// network settings.
typedef NetworkSetupRunner = Future<ProcessResult> Function(List<String> args);

Future<ProcessResult> _runNetworkSetup(List<String> args) =>
    Process.run('/usr/sbin/networksetup', args);

/// One kind of proxy on one network service, as `networksetup -getwebproxy`
/// and its sibling commands report it.
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

  /// Parses output like:
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

/// Proxy settings of one network service before we turned ours on.
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

  /// An empty list means no exceptions ("There aren't any bypass domains").
  final List<String> bypass;

  Map<String, Object> toJson() => {
    'web': web.toJson(),
    'secureWeb': secureWeb.toJson(),
    'socks': socks.toJson(),
    'bypass': bypass,
  };

  /// The same snapshot with our own proxy (`host:port`) treated as off.
  ///
  /// A proxy left on by a crash or a cut-short quit is still in the system
  /// when the next connect takes its snapshot. Saved as the user's setting,
  /// it would be "restored" on disconnect: the proxy stayed on a dead port
  /// and the Mac had no internet until the app was started again.
  MacServiceSnapshot withoutOurs(String host, int port) {
    MacProxyEntry clean(MacProxyEntry e) =>
        e.server == host && e.port == port ? MacProxyEntry.off : e;
    return MacServiceSnapshot(
      web: clean(web),
      secureWeb: clean(secureWeb),
      socks: clean(socks),
      bypass: bypass,
    );
  }

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

/// The macOS system proxy via `networksetup`.
///
/// On macOS the proxy is set per network service (Wi-Fi, Ethernet, USB
/// modem…). It is turned on for every enabled service: when the network
/// changes, traffic must not bypass the core through a service we forgot.
/// Each service's original settings are saved and restored as they were.
///
/// Same logic as the Windows registry: [lockLeak] keeps the proxy on a dead
/// port after the core crashes, [cleanupAfterCrash] at startup removes only
/// what we turned on ourselves.
class MacSystemProxy {
  MacSystemProxy({NetworkSetupRunner? run}) : _run = run ?? _runNetworkSetup;

  final NetworkSetupRunner _run;

  static const _savedKey = 'proxy.mac.saved';
  static const _oursKey = 'proxy.ours';

  /// Local addresses bypass the proxy: otherwise the browser proxies
  /// `localhost` and LAN addresses too.
  static const localBypass = [
    'localhost',
    '127.0.0.1',
    '::1',
    '*.local',
    '169.254/16',
  ];

  /// The "our proxy" label in settings: `http 127.0.0.1:10808` or
  /// `socks 127.0.0.1:10808`. After a crash it tells our proxy apart from
  /// someone else's (Proxyman, Charles, Clash and the like).
  static String oursLabel(String host, int port, {required bool socks}) =>
      '${socks ? 'socks' : 'http'} $host:$port';

  /// Parses `networksetup -listallnetworkservices`: the first line is a note,
  /// disabled services are marked with `*`.
  static List<String> parseServices(String output) => const LineSplitter()
      .convert(output)
      .skip(1)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('*'))
      .toList();

  /// Parses `networksetup -getproxybypassdomains`: the note "There aren't any
  /// bypass domains…" means an empty list.
  static List<String> parseBypass(String output) => const LineSplitter()
      .convert(output)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('There aren'))
      .toList();

  /// Exceptions are appended to the current ones, not replaced: the user's
  /// set comes back unchanged on disconnect.
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
    // The snapshot is written only on the first enable: a restart after a
    // crash must not overwrite the user's settings with ours.
    for (final service in list) {
      saved[service] ??= (await snapshot(service)).withoutOurs(host, port);
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
      // The service may be gone (USB modem unplugged): nothing to restore.
      if (!present.contains(service)) continue;
      await _restore(service, snap);
    }

    await prefs.remove(_oursKey);
    await prefs.remove(_savedKey);
  }

  Future<void> _restore(String service, MacServiceSnapshot snap) async {
    // An empty address is restored too: otherwise our 127.0.0.1 would stay in
    // the settings after disconnect (off, but visible to the user).
    // `-set…proxy` also turns the proxy on, so the state goes second.
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

  /// Kill switch: when the core dies the proxy stays on a dead port, so apps
  /// that follow the system proxy get a refusal instead of going direct.
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

  /// Rolls back a proxy left on after a crash. Touches the settings only if at
  /// least one service has exactly our proxy: otherwise the user has already
  /// set their own, and it must not be broken.
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
    // networksetup writes errors to stdout and does not always change the
    // exit code.
    final out = '${result.stdout}${result.stderr}'.trim();
    if (result.exitCode != 0 || out.contains('Error') || out.contains('** ')) {
      throw Exception('networksetup ${args.first} не выполнен: $out');
    }
  }
}
