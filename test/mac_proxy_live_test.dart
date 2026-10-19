import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/desktop_core.dart';
import 'package:client_vpn/mac_system_proxy.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Живая проверка Mac-1 на настоящей машине: ядро из macos/xray поднимает
/// локальный http-вход, системный прокси переключается на него через
/// `networksetup`, трафик идёт через ядро, а после остановки и после аварии
/// ядра настройки пользователя возвращаются.
///
/// Тест меняет сетевые настройки пользователя, поэтому выключен по умолчанию.
/// Запуск: `VPN_LIVE_PROXY=1 flutter test test/mac_proxy_live_test.dart`.
/// Нужны ядро (`bash scripts/download_xray_macos.sh`) и выход в интернет.
void main() {
  final live =
      Platform.environment['VPN_LIVE_PROXY'] == '1' && Platform.isMacOS;
  final skip = live ? null : 'VPN_LIVE_PROXY=1 и macOS';

  const port = 10871;
  final configJson = jsonEncode({
    'log': {'loglevel': 'warning'},
    'inbounds': [
      {
        'tag': 'http-in',
        'listen': '127.0.0.1',
        'port': port,
        'protocol': 'http',
      },
    ],
    'outbounds': [
      {'tag': 'direct', 'protocol': 'freedom'},
    ],
  });

  final mac = MacSystemProxy();
  late Map<String, MacServiceSnapshot> before;
  late Directory dir;

  Future<Map<String, MacServiceSnapshot>> snapshotAll() async => {
    for (final s in await mac.services()) s: await mac.snapshot(s),
  };

  void expectSame(
    Map<String, MacServiceSnapshot> a,
    Map<String, MacServiceSnapshot> b,
  ) {
    expect(a.keys, b.keys);
    for (final s in a.keys) {
      expect(jsonEncode(a[s]!.toJson()), jsonEncode(b[s]!.toJson()), reason: s);
    }
  }

  bool oursEverywhere(Map<String, MacServiceSnapshot> now) => now.values.every(
    (s) => s.web.enabled && s.web.server == '127.0.0.1' && s.web.port == port,
  );

  Future<VpnConfig> config() async {
    final file = File('${dir.path}/config.json');
    await file.writeAsString(configJson);
    return VpnConfig(name: 'live', json: configJson, path: file.path);
  }

  Future<int> curlViaProxy() async {
    final r = await Process.run('curl', [
      '-s',
      '-o',
      '/dev/null',
      '-w',
      '%{http_code}',
      '-m',
      '15',
      '-x',
      'http://127.0.0.1:$port',
      'https://www.apple.com/library/test/success.html',
    ]);
    return int.tryParse('${r.stdout}') ?? 0;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('client_vpn_live');
    before = await snapshotAll();
  });

  tearDown(() async {
    // Страховка: что бы ни случилось в кейсе, сеть пользователя возвращается.
    await SharedPreferences.getInstance();
    await mac.cleanupAfterCrash();
    await dir.delete(recursive: true);
  });

  test(
    'подключение и отключение: трафик через ядро, настройки вернулись',
    () async {
      final core = DesktopCore();
      final logs = <String>[];
      final sub = core.logs.listen(logs.add);
      final cfg = await config();

      await core.validate(cfg);
      await core.start(cfg);
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(
        oursEverywhere(await snapshotAll()),
        isTrue,
        reason: logs.join('\n'),
      );
      expect(await curlViaProxy(), 200, reason: logs.join('\n'));

      await core.stop();
      expectSame(await snapshotAll(), before);
      await sub.cancel();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'авария ядра: прокси держится на мёртвом порту, старт его снимает',
    () async {
      final core = DesktopCore();
      final down = Completer<void>();
      final sub = core.statusChanges.listen((on) {
        if (!on && !down.isCompleted) down.complete();
      });
      final cfg = await config();

      await core.validate(cfg);
      await core.start(cfg);
      await Future<void>.delayed(const Duration(seconds: 1));

      // Убиваем ядро извне, как его убил бы сбой.
      // Шаблон — рабочая папка этого процесса: чужие ядра не задеваются.
      await Process.run('pkill', [
        '-9',
        '-f',
        'client_vpn-$pid/config-stats.json',
      ]);
      await down.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(oursEverywhere(await snapshotAll()), isTrue);
      expect(await curlViaProxy(), isNot(200));

      // Следующий старт приложения.
      await core.recoverAfterCrash();
      expectSame(await snapshotAll(), before);
      await sub.cancel();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
