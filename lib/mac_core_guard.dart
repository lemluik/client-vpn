import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Защита от ядра-сироты на macOS — замена Job Object из Windows.
///
/// Job Object на macOS нет, поэтому две меры:
/// - сторож: отдельный `/bin/sh`, который раз в секунду проверяет, жив ли
///   процесс приложения, и снимает ядро, когда приложение исчезло (убито
///   извне, упало). Прокси остаётся на мёртвом порту — как на Windows, где
///   ядро умирает вместе с Job Object;
/// - метка ядра в настройках: PID и путь. Если сторож не успел (или его
///   тоже убили), при следующем старте [killOrphan] снимает ядро, оставшееся
///   от прошлого запуска.
class MacCoreGuard {
  static const _pidKey = 'core.mac.pid';
  static const _pathKey = 'core.mac.path';

  Process? _watcher;

  /// Скрипт сторожа. Ядро снимается, только если PID всё ещё принадлежит
  /// ему: номер мог перейти другому процессу.
  static String watcherScript({
    required int appPid,
    required int corePid,
    required String corePath,
  }) =>
      'while kill -0 $appPid 2>/dev/null; do sleep 1; done; '
      'case "\$(ps -p $corePid -o command= 2>/dev/null)" in '
      '${_shellQuote('$corePath run ')}*) kill -9 $corePid ;; esac';

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  /// Запоминает ядро и ставит сторожа. Ошибка сторожа подключение не рвёт:
  /// метка в настройках всё равно снимет сироту при следующем старте.
  Future<String> attach(int corePid, String corePath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_pidKey, corePid);
    await prefs.setString(_pathKey, corePath);

    try {
      _watcher = await Process.start('/bin/sh', [
        '-c',
        watcherScript(appPid: pid, corePid: corePid, corePath: corePath),
      ], mode: ProcessStartMode.detached);
      return 'Сторож ядра запущен: ядро не переживёт приложение';
    } on ProcessException catch (e) {
      return 'Сторож ядра не запущен ($e): ядро может пережить приложение';
    }
  }

  /// Ядро остановлено штатно: сторож и метка больше не нужны.
  Future<void> detach() async {
    _watcher?.kill(ProcessSignal.sigkill);
    _watcher = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pidKey);
    await prefs.remove(_pathKey);
  }

  /// Снимает ядро прошлого запуска, если оно ещё живо. Возвращает PID
  /// снятого ядра или null.
  Future<int?> killOrphan() async {
    final prefs = await SharedPreferences.getInstance();
    final corePid = prefs.getInt(_pidKey);
    final corePath = prefs.getString(_pathKey);
    await prefs.remove(_pidKey);
    await prefs.remove(_pathKey);
    if (corePid == null || corePath == null) return null;

    final ps = await Process.run('ps', ['-p', '$corePid', '-o', 'command=']);
    if (ps.exitCode != 0) return null;
    if (!isCoreCommand('${ps.stdout}', corePath)) return null;

    Process.killPid(corePid, ProcessSignal.sigkill);
    return corePid;
  }

  /// Командная строка процесса — наше ядро: тот же бинарник в режиме `run`.
  static bool isCoreCommand(String command, String corePath) {
    final line = command.trim();
    return line.startsWith('$corePath run ');
  }
}
