import 'package:client_vpn/desktop_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Логика Ф8 на уровне Dart: поток выхода старого процесса, проснувшийся
/// после остановки и нового запуска, не имеет права глушить новое ядро.
/// Нативная часть Android (TunnelService.kt) устроена так же — процесс и
/// поколение сессии, — но проверялась только чтением: инфраструктуры
/// Kotlin-тестов в проекте нет.
void main() {
  group('устаревший выход ядра (Ф8)', () {
    test('чужой процесс на месте текущего — выход устарел', () {
      final old = Object();
      final fresh = Object();
      expect(
        DesktopCore.exitIsStale(
          current: fresh,
          exited: old,
          session: 1,
          currentSession: 1,
        ),
        isTrue,
      );
    });

    test('сменилось поколение (стоп или новый старт) — выход устарел', () {
      final exited = Object();
      expect(
        DesktopCore.exitIsStale(
          current: exited,
          exited: exited,
          session: 1,
          currentSession: 2,
        ),
        isTrue,
      );
      expect(
        DesktopCore.exitIsStale(
          current: null,
          exited: exited,
          session: 1,
          currentSession: 2,
        ),
        isTrue,
      );
    });

    test('выход своей сессии не устаревает: килл-свитч остаётся в силе', () {
      final exited = Object();
      expect(
        DesktopCore.exitIsStale(
          current: exited,
          exited: exited,
          session: 3,
          currentSession: 3,
        ),
        isFalse,
      );
      // Аварийный выход до всякой остановки: процесс ещё не снят с учёта.
      expect(
        DesktopCore.exitIsStale(
          current: null,
          exited: exited,
          session: 3,
          currentSession: 3,
        ),
        isFalse,
      );
    });

    test('задержанный exit старого процесса после нового start молчит', () {
      // Последовательность поколений DesktopCore: spawn(1) → stop(2) →
      // spawn(3). Старый процесс добивался только теперь.
      final firstKernel = Object();
      final secondKernel = Object();
      var session = 0;
      Object? current;

      current = firstKernel;
      final firstGeneration = ++session; // spawn первого ядра
      current = null;
      session++; // stop: поколение увеличено
      current = secondKernel;
      final secondGeneration = ++session; // spawn нового ядра

      expect(
        DesktopCore.exitIsStale(
          current: current,
          exited: firstKernel,
          session: firstGeneration,
          currentSession: session,
        ),
        isTrue,
        reason: 'старое ядро не должно остановить новое',
      );
      expect(
        DesktopCore.exitIsStale(
          current: current,
          exited: secondKernel,
          session: secondGeneration,
          currentSession: session,
        ),
        isFalse,
        reason: 'своё ядро обрабатывается как прежде',
      );
    });
  });
}
