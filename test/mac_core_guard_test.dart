import 'dart:convert';
import 'dart:io';

import 'package:client_vpn/mac_core_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Ядро-сирота на macOS: сторож снимает ядро, когда процесс приложения
/// исчез, а метка в настройках — при следующем старте.
void main() {
  final xray = File(p.join('macos', 'xray', 'xray')).absolute.path;
  final ready = Platform.isMacOS && File(xray).existsSync();
  final skip = ready
      ? null
      : 'нужен macOS и bash scripts/download_xray_macos.sh';

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('командная строка ядра узнаётся только в режиме run', () {
    const path = '/Applications/client_vpn.app/Contents/Resources/xray/xray';
    expect(
      MacCoreGuard.isCoreCommand('$path run -config /tmp/c.json\n', path),
      isTrue,
    );
    expect(MacCoreGuard.isCoreCommand('$path version', path), isFalse);
    expect(MacCoreGuard.isCoreCommand('/usr/bin/other run', path), isFalse);
  });

  test('путь с пробелом и кавычкой в скрипте сторожа экранирован', () {
    final script = MacCoreGuard.watcherScript(
      appPid: 1,
      corePid: 2,
      corePath: "/Users/a b/it's/xray",
    );
    expect(script, contains(r"'/Users/a b/it'\''s/xray run '*)"));
  });

  Future<(Process, File)> startCore() async {
    final dir = await Directory.systemTemp.createTemp('guard');
    final cfg = File(p.join(dir.path, 'c.json'));
    await cfg.writeAsString(
      jsonEncode({
        'inbounds': <Object>[],
        'outbounds': [
          {'protocol': 'freedom'},
        ],
      }),
    );
    final core = await Process.start(xray, ['run', '-config', cfg.path]);
    core.stdout.drain<void>();
    core.stderr.drain<void>();
    return (core, cfg);
  }

  test('сторож снимает ядро, когда приложение исчезло', () async {
    final (core, cfg) = await startCore();
    final app = await Process.start('sleep', ['60']);

    final watcher = await Process.start('/bin/sh', [
      '-c',
      MacCoreGuard.watcherScript(
        appPid: app.pid,
        corePid: core.pid,
        corePath: xray,
      ),
    ]);

    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(
      Process.killPid(core.pid, ProcessSignal.sigcont),
      isTrue,
      reason: 'ядро живо, пока живо приложение',
    );

    app.kill(ProcessSignal.sigkill);
    final code = await core.exitCode.timeout(const Duration(seconds: 5));
    expect(code, isNot(0));
    await watcher.exitCode.timeout(const Duration(seconds: 5));
    await cfg.parent.delete(recursive: true);
  }, skip: skip);

  test('метка снимает ядро прошлого запуска при старте', () async {
    final (core, cfg) = await startCore();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('core.mac.pid', core.pid);
    await prefs.setString('core.mac.path', xray);

    expect(await MacCoreGuard().killOrphan(), core.pid);
    await core.exitCode.timeout(const Duration(seconds: 5));
    expect(prefs.getInt('core.mac.pid'), isNull);
    await cfg.parent.delete(recursive: true);
  }, skip: skip);

  test('чужой процесс с тем же PID не трогается', () async {
    final other = await Process.start('sleep', ['30']);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('core.mac.pid', other.pid);
    await prefs.setString('core.mac.path', xray);

    expect(await MacCoreGuard().killOrphan(), isNull);
    expect(Process.killPid(other.pid, ProcessSignal.sigcont), isTrue);
    other.kill(ProcessSignal.sigkill);
  }, skip: Platform.isMacOS ? null : 'macOS');
}
