import 'dart:async';
import 'dart:io';

import 'package:client_vpn/path_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// Проба, которой тест отвечает сам: заход не завершится, пока ему не скажут.
/// Без этого короткие паузы между заходами накручивают лишние пробы и
/// проверить «сколько раз спросили» невозможно.
class ManualAttempt {
  final List<Completer<bool>> _gates = [];
  final List<Uri> targets = [];

  int get calls => targets.length;

  Future<bool> call(Uri endpoint) {
    targets.add(endpoint);
    final gate = Completer<bool>();
    _gates.add(gate);
    return gate.future;
  }

  /// Отвечает на ближайший заход — дождавшись его — и ждёт следующего.
  Future<void> answer(bool alive) async {
    await nextCall();
    release(alive);
    await nextCall();
  }

  void release(bool alive) => _gates.removeAt(0).complete(alive);

  Future<void> nextCall() async {
    while (_gates.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }
}

/// Пауза между заходами, которая заведомо не наступит внутри испытания:
/// следующий заход нужен только там, где его явно попросили короткой паузой.
const later = Duration(seconds: 1);

/// Короткая пауза: проверка идёт настоящими таймерами, ждать рабочие
/// интервалы незачем.
const fast = Duration(milliseconds: 1);

const endpoint = 'https://probe.test/204';

PathProbe probe(
  ManualAttempt attempt, {
  bool reachesCore = true,
  Duration retry = later,
  Duration deadRetry = later,
  Duration idle = later,
  int failuresBeforeDead = 2,
}) => PathProbe(
  attempt: attempt.call,
  reachesCore: () => reachesCore,
  retry: retry,
  deadRetry: deadRetry,
  idle: idle,
  failuresBeforeDead: failuresBeforeDead,
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  group('проба пути до узла', () {
    test('живой ответ подтверждает путь и пробует точку из настроек', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt)..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await attempt.nextCall();
      expect(watching.state, PathState.checking);

      attempt.release(true);
      await settle();

      expect(watching.state, PathState.live);
      expect(watching.isRunning, isTrue);
      expect(attempt.targets, [Uri.parse(endpoint)]);
    });

    test(
      'один провал защитой не считается, но и не обрывает проверку',
      () async {
        final attempt = ManualAttempt();
        final watching = probe(attempt)..start(Uri.parse(endpoint));
        addTearDown(watching.dispose);

        await attempt.nextCall();
        attempt.release(false);
        await settle();

        expect(watching.state, PathState.checking);
        expect(watching.isRunning, isTrue);
        expect(attempt.calls, 1);
      },
    );

    test('два провала подряд делают путь мёртвым', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt, retry: fast)..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await attempt.answer(false);
      expect(watching.state, PathState.checking);

      attempt.release(false);
      await settle();

      expect(watching.state, PathState.dead);
      expect(attempt.calls, 2);
    });

    test('вернувшийся ответ оживляет мёртвый путь', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt, retry: fast, deadRetry: fast)
        ..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await attempt.answer(false);
      await attempt.answer(false);
      expect(watching.state, PathState.dead);

      attempt.release(true);
      await settle();

      expect(watching.state, PathState.live);
    });

    test('живой путь держится после одного провала', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt, idle: fast, retry: fast)
        ..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await attempt.answer(true);
      expect(watching.state, PathState.live);

      attempt.release(false);
      await settle();
      expect(watching.state, PathState.live);
      expect(watching.isRunning, isTrue);
      expect(attempt.calls, greaterThanOrEqualTo(2));
    });

    test('без пути через ядро проба не начинается', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt, reachesCore: false)
        ..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await settle();

      expect(watching.state, PathState.unknown);
      expect(watching.isRunning, isFalse);
      expect(attempt.calls, 0);
    });

    test('снятая проверка не продолжает пробовать', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt)..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await attempt.nextCall();
      attempt.release(true);
      await settle();
      final calls = attempt.calls;

      watching.stop();
      await settle();

      expect(watching.state, PathState.unknown);
      expect(watching.isRunning, isFalse);
      expect(attempt.calls, calls);
    });

    test('ответ снятой проверки состояние не меняет', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt)..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await attempt.nextCall();
      watching.stop();
      attempt.release(true);
      await settle();

      expect(watching.state, PathState.unknown);
      expect(attempt.calls, 1);
    });

    test('повторный запуск начинает проверку с нуля', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt, retry: fast)..start(Uri.parse(endpoint));
      addTearDown(watching.dispose);

      await attempt.answer(false);
      attempt.release(false);
      await settle();
      expect(watching.state, PathState.dead);

      watching.start(Uri.parse(endpoint));
      expect(watching.state, PathState.checking);

      await attempt.nextCall();
      attempt.release(true);
      await settle();

      expect(watching.state, PathState.live);
    });

    test('события состояния приходят подписчику', () async {
      final attempt = ManualAttempt();
      final watching = probe(attempt, retry: fast, deadRetry: fast);
      addTearDown(watching.dispose);
      final seen = <PathState>[];
      final subscription = watching.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      watching.start(Uri.parse(endpoint));
      await attempt.answer(false);
      await attempt.answer(false);
      attempt.release(true);
      await settle();

      expect(seen, [PathState.checking, PathState.dead, PathState.live]);
    });
  });

  group('общий срок пробы (Ф5)', () {
    /// Сервер, который присылает заголовки и не завершает тело: прежняя проба
    /// ограничивала только открытие запроса и ожидание заголовков, и `drain()`
    /// такого ответа висел навсегда — следующая проба не ставилась.
    Future<HttpServer> hangingServer() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('заголовки пришли, тело не закончено');
        await request.response.flush();
        // Ответ намеренно не закрывается.
      });
      addTearDown(() => server.close(force: true));
      return server;
    }

    test('зависшее тело обрывается общим deadline, проба провалена', () async {
      final server = await hangingServer();
      final uri = Uri.parse('http://127.0.0.1:${server.port}/generate_204');

      final watch = Stopwatch()..start();
      final alive = await httpAttempt(
        uri,
        timeout: const Duration(milliseconds: 300),
      );
      watch.stop();

      expect(alive, isFalse);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(250));
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });

    test('обычный короткий ответ проходит пробу', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
      });

      final alive = await httpAttempt(
        Uri.parse('http://127.0.0.1:${server.port}/generate_204'),
        timeout: const Duration(seconds: 5),
      );

      expect(alive, isTrue);
    });

    test('после зависшей пробы следующая проба состоится', () async {
      final server = await hangingServer();
      final uri = Uri.parse('http://127.0.0.1:${server.port}/generate_204');
      var calls = 0;

      final watching = PathProbe(
        attempt: (endpoint) async {
          calls++;
          return httpAttempt(endpoint, timeout: const Duration(milliseconds: 150));
        },
        reachesCore: () => true,
        retry: const Duration(milliseconds: 10),
        deadRetry: const Duration(milliseconds: 10),
      )..start(uri);
      addTearDown(watching.dispose);

      await Future<void>.delayed(const Duration(milliseconds: 900));

      // Без общего deadline первый же заход висел бы вечно и calls остался 1.
      expect(calls, greaterThanOrEqualTo(3));
      expect(watching.state, PathState.dead);
    });
  });
}
