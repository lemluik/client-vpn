import 'dart:io';

import 'package:client_vpn/system_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _regPath =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

/// Живая проверка отката системного прокси после внешнего убийства процесса.
///
/// Тест пишет в реестр настоящего пользователя, поэтому выключен по умолчанию.
/// Запуск: `VPN_LIVE_PROXY=1 flutter test test/system_proxy_live_test.dart`.
/// Снятые значения возвращаются в конце каждого кейса.
void main() {
  final live = Platform.environment['VPN_LIVE_PROXY'] == '1';
  late String? beforeServer;
  late bool beforeEnable;
  late String? beforeOverride;

  String? skipOf(String reason) => live ? null : reason;

  Future<void> writeReg(String name, String value, String type) async {
    final result = await Process.run('reg', [
      'add',
      _regPath,
      '/v',
      name,
      '/t',
      type,
      '/d',
      value,
      '/f',
    ]);
    expect(result.exitCode, 0, reason: 'reg add $name: ${result.stderr}');
  }

  /// Возврат к снимку, снятому в setUp, прямыми записями в реестр.
  Future<void> restoreSnapshot() async {
    await writeReg('ProxyEnable', beforeEnable ? '1' : '0', 'REG_DWORD');
    await writeReg('ProxyServer', beforeServer ?? '', 'REG_SZ');
    await writeReg('ProxyOverride', beforeOverride ?? '', 'REG_SZ');
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  setUp(() async {
    // Хранилище маркеров — in-memory: снимок реестра при этом настоящий.
    SharedPreferences.setMockInitialValues({});
    beforeServer = await SystemProxy.getProxyServer();
    beforeEnable = await SystemProxy.isEnabled;
    beforeOverride = await SystemProxy.getProxyOverride();
  });

  test(
    'убитый процесс: прокси, включённый нами, снят при следующем старте',
    () async {
      // Состояние после внешнего убийства: в реестре осталась наша запись,
      // приложение о ней не помнит, пока не вызовет recover().
      await SystemProxy.enable('127.0.0.1', 10856);
      expect(await SystemProxy.isEnabled, isTrue);
      expect(await SystemProxy.getProxyServer(), '127.0.0.1:10856');
      expect(await SystemProxy.getProxyOverride(), contains('<local>'));

      await SystemProxy.cleanupAfterCrash();

      expect(await SystemProxy.isEnabled, beforeEnable);
      expect(await SystemProxy.getProxyServer(), beforeServer);
      expect(
        await SystemProxy.getProxyOverride(),
        beforeOverride ?? '',
        reason: 'метку <local> надо снять вместе с остальными записями',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('proxy.ours'), isNull);
    },
    skip: skipOf('нужен VPN_LIVE_PROXY=1: кейс пишет в реестр'),
  );

  test(
    'килл-свитч: после падения ядра прокси остаётся на мёртвом порту',
    () async {
      await SystemProxy.enable('127.0.0.1', 10857);
      // Авария ядра: возвращаемые настройки пользователя не восстанавливаются.
      await SystemProxy.lockLeak();

      expect(await SystemProxy.isEnabled, isTrue);
      expect(await SystemProxy.getProxyServer(), '127.0.0.1:10857');

      // Явное отключение возвращает то, что было до нас.
      await SystemProxy.disable();
      expect(await SystemProxy.isEnabled, beforeEnable);
      expect(await SystemProxy.getProxyServer(), beforeServer);
      await restoreSnapshot();
    },
    skip: skipOf('нужен VPN_LIVE_PROXY=1: кейс пишет в реестр'),
  );

  test(
    'чужой прокси не трогается: откат только при совпадении с нашей записью',
    () async {
      await SystemProxy.enable('127.0.0.1', 10856);
      // Пользователь успел поставить свой прокси (Fiddler, Clash, корпоративный).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('proxy.ours', 'socks=127.0.0.1:8888');

      await SystemProxy.cleanupAfterCrash();

      expect(await SystemProxy.getProxyServer(), '127.0.0.1:10856');
      expect(await SystemProxy.isEnabled, isTrue);
      expect(prefs.getString('proxy.ours'), isNull);

      await restoreSnapshot();
    },
    skip: skipOf('нужен VPN_LIVE_PROXY=1: кейс пишет в реестр'),
  );
}
