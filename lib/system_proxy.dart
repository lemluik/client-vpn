import 'dart:ffi';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

typedef _SetOptionNative = Int32 Function(IntPtr, IntPtr, Int32);
typedef _SetOptionDart = int Function(int, int, int);

class SystemProxy {
  static const _regPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _savedServerKey = 'proxy.saved_server';
  static const _savedEnableKey = 'proxy.saved_enable';
  static const _oursKey = 'proxy.ours';

  static const _settingsChanged = 39;
  static const _refresh = 37;

  static final _internetSetOption = DynamicLibrary.open('wininet.dll')
      .lookupFunction<_SetOptionNative, _SetOptionDart>('InternetSetOptionW');

  static Future<void> enable(
    String host,
    int port, {
    bool socks = false,
  }) async {
    final server = socks ? 'socks=$host:$port' : '$host:$port';

    await _saveOriginal();
    await _writeString('ProxyServer', server);
    await _writeDword('ProxyEnable', 1);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_oursKey, server);

    _notify();
  }

  static Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_oursKey) == null) return;

    final savedServer = prefs.getString(_savedServerKey);
    final savedEnable = prefs.getBool(_savedEnableKey) ?? false;

    await _writeDword('ProxyEnable', savedEnable ? 1 : 0);
    if (savedServer != null && savedServer.isNotEmpty) {
      await _writeString('ProxyServer', savedServer);
    }

    await prefs.remove(_oursKey);
    await prefs.remove(_savedServerKey);
    await prefs.remove(_savedEnableKey);

    _notify();
  }

  /// Откатывает прокси, оставшийся включённым после аварийного завершения.
  /// Трогает прокси только если он совпадает с тем, что включали мы сами —
  /// иначе можно сломать локальный прокси пользователя (Fiddler, Clash и т.п.).
  static Future<void> cleanupAfterCrash() async {
    final prefs = await SharedPreferences.getInstance();
    final ours = prefs.getString(_oursKey);
    if (ours == null) return;

    if (await isEnabled && await getProxyServer() == ours) {
      await disable();
      return;
    }

    await prefs.remove(_oursKey);
    await prefs.remove(_savedServerKey);
    await prefs.remove(_savedEnableKey);
  }

  static Future<void> _saveOriginal() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_savedEnableKey)) return;

    await prefs.setString(_savedServerKey, await getProxyServer() ?? '');
    await prefs.setBool(_savedEnableKey, await isEnabled);
  }

  static Future<void> _writeString(String name, String value) async {
    final result = await Process.run('reg', [
      'add',
      _regPath,
      '/v',
      name,
      '/t',
      'REG_SZ',
      '/d',
      value,
      '/f',
    ]);
    if (result.exitCode != 0) {
      throw Exception('Не удалось записать $name: ${result.stderr}');
    }
  }

  static Future<void> _writeDword(String name, int value) async {
    final result = await Process.run('reg', [
      'add',
      _regPath,
      '/v',
      name,
      '/t',
      'REG_DWORD',
      '/d',
      '$value',
      '/f',
    ]);
    if (result.exitCode != 0) {
      throw Exception('Не удалось записать $name: ${result.stderr}');
    }
  }

  static void _notify() {
    _internetSetOption(_settingsChanged, 0, 0);
    _internetSetOption(_refresh, 0, 0);
  }

  static Future<bool> get isEnabled async {
    final result = await Process.run('reg', [
      'query',
      _regPath,
      '/v',
      'ProxyEnable',
    ]);
    if (result.exitCode != 0) return false;

    final match = RegExp(r'ProxyEnable\s+REG_DWORD\s+(0x[0-9a-fA-F]+|\d+)')
        .firstMatch(result.stdout.toString());
    if (match == null) return false;

    final value = match.group(1)!;
    return value.startsWith('0x')
        ? int.parse(value.substring(2), radix: 16) != 0
        : int.parse(value) != 0;
  }

  static Future<String?> getProxyServer() async {
    final result = await Process.run('reg', [
      'query',
      _regPath,
      '/v',
      'ProxyServer',
    ]);
    if (result.exitCode != 0) return null;

    return RegExp(r'ProxyServer\s+REG_SZ\s+(.+)')
        .firstMatch(result.stdout.toString())
        ?.group(1)
        ?.trim();
  }
}
