import 'dart:async';
import 'dart:io';

import 'package:client_vpn/windows_guard.dart';
import 'package:flutter_test/flutter_test.dart';

/// Проверки Win32-защиты на настоящем Windows: мьютекс и Job Object.
///
/// Кейсы дёргают ядро Windows, поэтому на других платформах отключены.
void main() {
  final windows = Platform.isWindows;
  String? skipOf(String reason) => windows ? null : reason;

  test(
    'мьютекс даёт один экземпляр: второй захват того же имени не проходит',
    () async {
      final first = SingleInstanceLock.tryAcquire('ClientVpn.Test.Mutex.v1');
      expect(first, isNotNull, reason: 'первый захват обязан удасться');

      expect(
        SingleInstanceLock.tryAcquire('ClientVpn.Test.Mutex.v1'),
        isNull,
        reason: 'имя занято — приложение уже запущено',
      );

      first!.release();
      expect(
        SingleInstanceLock.tryAcquire('ClientVpn.Test.Mutex.v1'),
        isNotNull,
        reason: 'после освобождения имя свободно',
      );
    },
    skip: skipOf('нужен Windows: работает с kernel32'),
  );

  test(
    'другой процесс видит наш мьютекс и не стартует',
    () async {
      final ours = SingleInstanceLock.tryAcquire('ClientVpn.Test.Mutex.v2');
      expect(ours, isNotNull);

      // PowerShell-процесс пытается занять то же имя и ждёт две секунды.
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        r"$m = New-Object System.Threading.Mutex($false, 'ClientVpn.Test.Mutex.v2'); "
        r"if ($m.WaitOne(2000)) { 'FREE' } else { 'BUSY' }",
      ]).timeout(const Duration(seconds: 30));

      expect(
        '${result.stdout}'.trim(),
        'BUSY',
        reason: 'stderr: ${result.stderr}',
      );
      ours!.release();
    },
    skip: skipOf('нужен Windows: работает с kernel32'),
  );

  test(
    'Job Object убивает дочерний процесс вместе с держателем ручки',
    () async {
      final job = CoreKillJob.create();
      expect(job, isNotNull);
      expect(
        job!.killOnCloseArmed,
        isTrue,
        reason: 'флаг kill-on-close должен приниматься ядром Windows',
      );

      // Долгий процесс: сам он завершится только через 30 секунд.
      final child = await Process.start('ping', ['-n', '30', '127.0.0.1']);
      var finished = false;
      unawaited(child.exitCode.then((_) => finished = true));
      addTearDown(() {
        if (!finished) child.kill(ProcessSignal.sigkill);
      });

      expect(
        job.assign(child.pid),
        isTrue,
        reason:
            'посадка не удалась — процесс уже в чужом jobs '
            '(вложенные jobs разрешены с Windows 8)',
      );

      // Закрытие последней ручки jobs завершает его участников: проверка
      // того, что убийство приложения не оставит ядро-сироту.
      job.close();
      final code = await child.exitCode.timeout(const Duration(seconds: 10));
      expect(code, isNotNull, reason: 'процесс обязан завершиться');
    },
    skip: skipOf('нужен Windows: работает с kernel32'),
  );
}
