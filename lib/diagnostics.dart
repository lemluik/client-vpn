import 'dart:async';
import 'dart:io';

import 'app_proxy.dart';
import 'log_mask.dart';

/// Итог диагностики — три состояния, как в сквозной пробе самопроверки узла.
///
/// [works] — ожидаемый ответ пришёл через туннель; [failureConfirmed] — туннель
/// не передаёт трафик, а контрольный адрес доступен напрямую (отказ доказан);
/// [unknown] — проверить нельзя: нет входа через ядро, контрольные адреса сами
/// недоступны или проба не запустилась. «Не удалось проверить» не есть ни норма,
/// ни подтверждённая авария.
enum DiagVerdict { works, failureConfirmed, unknown }

/// Причина прерывания проверки. «Соединение отключено» само по себе не говорит,
/// кто его отключил: пользователь, остановка ядра или автоматическое
/// переподключение — разные события, и отчёт обязан их различать.
enum DiagCancelReason { user, coreStopped, recovery }

/// Пояснение причины прерывания для отчёта.
String cancelReasonName(DiagCancelReason reason) => switch (reason) {
  DiagCancelReason.user => 'пользователь отключил соединение',
  DiagCancelReason.coreStopped => 'ядро остановилось во время проверки',
  DiagCancelReason.recovery => 'шло автоматическое переподключение',
};

/// Этап, на котором остановилась проверка. Порядок — от устройства к пути.
enum DiagStage { network, subscription, core, path, switchEntry }

/// Класс отказа одной HTTP-пробы. Нужен, чтобы отличить «TCP доступен, HTTP не
/// проходит» от «вход недоступен» и от таймаута.
enum ProbeFailure { none, refused, timeout, dns, tls, http, other }

/// Результат одной пробы контрольного адреса.
class ProbeOutcome {
  const ProbeOutcome({
    this.statusCode,
    this.failure = ProbeFailure.none,
    this.elapsed = Duration.zero,
  });

  /// Код ответа, если обмен состоялся; null — ответа не было.
  final int? statusCode;
  final ProbeFailure failure;
  final Duration elapsed;

  /// Ответ пришёл (код любой). Сам по себе успехом туннеля не считается:
  /// успех — только ожидаемый код, и только через туннель.
  bool get responded => statusCode != null;
}

/// Контрольный адрес с ожидаемым кодом ответа. Два независимых адреса нужны,
/// чтобы отказ одного сайта не выдавался за отказ туннеля.
class ControlEndpoint {
  const ControlEndpoint(this.label, this.uri, this.expectedCodes);

  /// Нейтральная метка для отчёта («A», «B»): сам адрес в отчёт не попадает.
  final String label;
  final Uri uri;
  final Set<int> expectedCodes;

  bool matches(int? code) => code != null && expectedCodes.contains(code);
}

/// Два независимых контрольных адреса разных провайдеров. Схема `http`: проба
/// проверяет факт обмена, а TLS-рукопожатие с зарубежным сайтом у части абонентов
/// зависает при живом туннеле (замер 26.10.2026). Адреса нейтральные (У-3):
/// клиент универсальный, наши узлы сюда не зашиваются.
final List<ControlEndpoint> defaultControlEndpoints = [
  ControlEndpoint(
    'A',
    Uri.parse('http://connectivitycheck.gstatic.com/generate_204'),
    const {204},
  ),
  ControlEndpoint('B', Uri.parse('http://cp.cloudflare.com/'), const {204}),
];

/// Проба контрольного адреса. [viaTunnel] — через локальный вход ядра
/// ([AppProxy.findProxy]); false — напрямую, только для проверки доступности
/// самого контрольного адреса (успехом туннеля никогда не считается).
typedef ControlProbe =
    Future<ProbeOutcome> Function(
      Uri endpoint, {
      required bool viaTunnel,
      Duration timeout,
    });

/// Предел тела ответа: контрольные адреса отвечают 204 без тела, но чужой или
/// битый ответ не должен вычитываться целиком (ограничение трафика проб).
const int probeMaxBodyBytes = 64 * 1024;

/// Настоящая проба собственным трафиком приложения. Весь обмен ограничен общим
/// сроком [timeout] (Ф5): сервер, приславший заголовки и не завершающий тело,
/// не имеет права повесить диагностику.
Future<ProbeOutcome> tunnelControlProbe(
  Uri endpoint, {
  required bool viaTunnel,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final watch = Stopwatch()..start();
  final client = HttpClient()..connectionTimeout = timeout;
  client.findProxy = viaTunnel ? AppProxy.findProxy : (Uri _) => 'DIRECT';
  try {
    final code = await _exchange(client, endpoint).timeout(timeout);
    return ProbeOutcome(statusCode: code, elapsed: watch.elapsed);
  } on TimeoutException {
    return ProbeOutcome(failure: ProbeFailure.timeout, elapsed: watch.elapsed);
  } on SocketException catch (error) {
    final message = error.message.toLowerCase();
    final code = error.osError?.errorCode;
    // Отказ соединения (порт закрыт) — вход недоступен; неудачный резолв — DNS;
    // сброс уже принятого соединения — TCP был, обмен не состоялся (не DNS).
    // Коды отказа: 111 — Linux ECONNREFUSED, 10061 — Winsock WSAECONNREFUSED,
    // 1225 — Win32 ERROR_CONNECTION_REFUSED (русская локаль: сообщение не
    // содержит «refused», поэтому опора на код, а не на текст).
    final ProbeFailure failure;
    if (code == 111 ||
        code == 10061 ||
        code == 1225 ||
        message.contains('refused')) {
      failure = ProbeFailure.refused;
    } else if (code == 11001 ||
        code == 11004 ||
        message.contains('failed host lookup') ||
        message.contains('nodename')) {
      failure = ProbeFailure.dns;
    } else {
      failure = ProbeFailure.other;
    }
    return ProbeOutcome(failure: failure, elapsed: watch.elapsed);
  } on HandshakeException {
    return ProbeOutcome(failure: ProbeFailure.tls, elapsed: watch.elapsed);
  } on HttpException {
    return ProbeOutcome(failure: ProbeFailure.http, elapsed: watch.elapsed);
  } on Object {
    return ProbeOutcome(failure: ProbeFailure.other, elapsed: watch.elapsed);
  } finally {
    client.close(force: true);
  }
}

Future<int> _exchange(HttpClient client, Uri endpoint) async {
  final request = await client.getUrl(endpoint);
  final response = await request.close();
  final code = response.statusCode;
  // Тело читаем с пределом и обрываем: диагностика не должна тянуть мегабайты.
  var read = 0;
  await for (final chunk in response) {
    read += chunk.length;
    if (read >= probeMaxBodyBytes) break;
  }
  return code;
}

/// Сведения об окружении для отчёта. Только то, что не является тайной:
/// версии, платформа, тип сети. Адреса узлов и ключи сюда не попадают.
class DiagFacts {
  const DiagFacts({
    required this.appVersion,
    required this.coreVersion,
    required this.platform,
    required this.osVersion,
    required this.networkType,
  });

  final String appVersion;
  final String coreVersion;

  /// 'android', 'windows', 'macos', 'linux'.
  final String platform;

  /// Версия ОС (на Android — версия Android).
  final String osVersion;

  /// 'wifi', 'mobile', 'ethernet', 'none' — тип сети на момент проверки.
  final String networkType;
}

/// Итог одного этапа (сеть, подписка, ядро).
class StageResult {
  const StageResult(this.stage, this.ok, this.detail, {this.elapsed = Duration.zero});

  final DiagStage stage;
  final bool ok;

  /// Короткое пояснение для отчёта; без адресов и ключей.
  final String detail;
  final Duration elapsed;
}

/// Вход (регион выхода), который проверяется отдельно. Метка — имя региона,
/// а не адрес узла: адрес в отчёт не попадает.
class EntryCandidate {
  const EntryCandidate(this.key, this.label);

  final String key;
  final String label;
}

/// Результат проверки одного входа через реальный туннель.
class EntryResult {
  const EntryResult({
    required this.entry,
    required this.verdict,
    required this.stage,
    required this.controls,
    this.elapsed = Duration.zero,
    this.recovery,
    this.note = '',
  });

  final EntryCandidate entry;
  final DiagVerdict verdict;
  final DiagStage stage;

  /// Наблюдённый код по каждому контрольному адресу (метка → код или null).
  final Map<String, int?> controls;
  final Duration elapsed;

  /// Длительность восстановления после переключения на этот вход.
  final Duration? recovery;
  final String note;
}

/// Бюджет фоновой диагностики: общий срок, предел проб и тело ответа ограничены.
/// Фоновые пробы редкие: автоматический запуск происходит один раз на эпизод
/// устойчивого отказа, а не в цикле.
class DiagnosticsBudget {
  const DiagnosticsBudget({
    this.total = const Duration(seconds: 30),
    this.probeTimeout = const Duration(seconds: 6),
    this.maxEntries = 8,
  });

  final Duration total;
  final Duration probeTimeout;
  final int maxEntries;
}

/// Отчёт диагностики. Собирается из структурных полей, поэтому секретов в нём
/// нет по построению; [toShareText] дополнительно маскирует каждую строку.
class DiagnosticsReport {
  const DiagnosticsReport({
    required this.facts,
    required this.stages,
    required this.entries,
    required this.verdict,
    required this.startedAt,
    this.totalElapsed = Duration.zero,
    this.switchTested = false,
    this.cancelled = false,
    this.cancelReason,
  });

  final DiagFacts facts;
  final List<StageResult> stages;
  final List<EntryResult> entries;
  final DiagVerdict verdict;
  final DateTime startedAt;
  final Duration totalElapsed;

  /// Проверялось ли переключение входа (активный тест, только по нажатию).
  final bool switchTested;

  /// Проверка прервана: отчёт неполный. Причина — в [cancelReason].
  final bool cancelled;

  /// Кто прервал проверку: пользователь, остановка ядра или автоматическое
  /// переподключение. null — проверка не прерывалась (или причина не передана).
  final DiagCancelReason? cancelReason;

  /// Короткий понятный результат для экрана.
  String summary() {
    if (cancelled) {
      return switch (cancelReason) {
        DiagCancelReason.coreStopped => 'Проверка прервана: ядро остановилось',
        DiagCancelReason.recovery =>
          'Проверка прервана: шло автоматическое переподключение',
        _ => 'Проверка прервана: соединение отключено пользователем',
      };
    }
    return switch (verdict) {
      DiagVerdict.works => 'Соединение работает',
      DiagVerdict.failureConfirmed => 'Отказ подтверждён: трафик через туннель не идёт',
      DiagVerdict.unknown => 'Не удалось проверить соединение',
    };
  }

  /// Текст для «Поделиться диагностикой»: без UUID, ключей, токенов, ссылок
  /// подписки, адресов узлов и посещаемых сайтов, без персональных данных.
  /// Контрольные адреса названы метками (A/B), входы — именем региона.
  String toShareText() {
    final buffer = StringBuffer()
      ..writeln('Диагностика соединения')
      ..writeln('Итог: ${summary()}')
      ..writeln('Приложение: ${facts.appVersion}')
      ..writeln('Ядро: ${facts.coreVersion}')
      ..writeln('Платформа: ${facts.platform} ${facts.osVersion}')
      ..writeln('Сеть: ${facts.networkType}')
      ..writeln('Начало: ${startedAt.toIso8601String()}')
      ..writeln('Длительность: ${totalElapsed.inMilliseconds} мс')
      ..writeln('Переключение входа: ${switchTested ? 'да' : 'нет'}');
    if (cancelled) {
      buffer.writeln(
        'Причина прерывания: '
        '${cancelReason == null ? 'соединение отключено' : cancelReasonName(cancelReason!)}',
      );
    }
    for (final stage in stages) {
      buffer.writeln(
        'Этап ${stageName(stage.stage)}: ${stage.ok ? 'ок' : 'отказ'} '
        '(${stage.elapsed.inMilliseconds} мс) — ${stage.detail}',
      );
    }
    for (final entry in entries) {
      buffer.writeln(
        'Вход «${entry.entry.label}»: ${verdictName(entry.verdict)} '
        '(${entry.elapsed.inMilliseconds} мс)',
      );
      entry.controls.forEach((label, code) {
        buffer.writeln(
          '  контрольный адрес $label: ${code ?? 'нет ответа'}',
        );
      });
      if (entry.recovery != null) {
        buffer.writeln(
          '  восстановление: ${entry.recovery!.inMilliseconds} мс',
        );
      }
      if (entry.note.isNotEmpty) buffer.writeln('  ${entry.note}');
    }
    // Защита в глубину: даже если в пояснение этапа попадёт адрес или ключ,
    // маскирование уберёт его перед отправкой наружу.
    return maskLog(buffer.toString().split('\n'));
  }
}

/// Имя этапа для отчёта.
String stageName(DiagStage stage) => switch (stage) {
  DiagStage.network => 'сеть',
  DiagStage.subscription => 'подписка',
  DiagStage.core => 'ядро',
  DiagStage.path => 'путь',
  DiagStage.switchEntry => 'переключение',
};

/// Имя итога для отчёта.
String verdictName(DiagVerdict verdict) => switch (verdict) {
  DiagVerdict.works => 'работает',
  DiagVerdict.failureConfirmed => 'отказ подтверждён',
  DiagVerdict.unknown => 'не удалось проверить',
};

/// Окружение диагностики: всё внедряется, чтобы испытание не ходило в сеть и
/// не поднимало настоящее ядро. Реальное окружение собирает [AppState].
class DiagnosticsEnv {
  const DiagnosticsEnv({
    required this.facts,
    required this.reachesCore,
    required this.probe,
    required this.checkNetwork,
    required this.checkSubscription,
    required this.checkCore,
    required this.entries,
    required this.currentEntry,
    required this.switchTo,
    required this.restore,
    required this.cancelled,
    this.cancelReason,
    this.clock = DateTime.now,
    this.controlEndpoints,
  });

  final DiagFacts Function() facts;
  final bool Function() reachesCore;
  final ControlProbe probe;
  final Future<StageResult> Function() checkNetwork;
  final Future<StageResult> Function() checkSubscription;
  final Future<StageResult> Function() checkCore;
  final List<EntryCandidate> Function() entries;
  final EntryCandidate? Function() currentEntry;

  /// Переключает действующий туннель на вход (пересборка конфига и перезапуск).
  final Future<void> Function(EntryCandidate target) switchTo;

  /// Возвращает исходный вход после активного теста переключения.
  final Future<void> Function() restore;

  /// Проверка больше не имеет смысла: пользователь отключился, ядро
  /// остановилось или идёт автоматическое переподключение. Поздний результат
  /// не должен ничего менять.
  final bool Function() cancelled;

  /// Классификация прерывания для отчёта. Если не задана, прерванная проверка
  /// считается отключением пользователя (прежнее поведение).
  final DiagCancelReason? Function()? cancelReason;
  final DateTime Function() clock;
  final List<ControlEndpoint>? controlEndpoints;
}

/// Оркестратор диагностики. Проверка пути идёт только через реальный туннель
/// ([AppProxy]); прямой обход успехом не считается. Контрольные адреса напрямую
/// опрашиваются лишь чтобы отличить отказ туннеля от недоступности самого сайта.
class ConnectionDiagnostics {
  ConnectionDiagnostics({
    required this.env,
    this.budget = const DiagnosticsBudget(),
  });

  final DiagnosticsEnv env;
  final DiagnosticsBudget budget;

  List<ControlEndpoint> get _controls =>
      env.controlEndpoints ?? defaultControlEndpoints;

  /// Причина прерывания на момент отчёта; без классификатора — отключение
  /// пользователя (прежнее поведение окружений, не задающих причину).
  DiagCancelReason? _reason() =>
      env.cancelReason?.call() ??
      (env.cancelled() ? DiagCancelReason.user : null);

  /// Проверка текущего входа: сеть, подписка, ядро, путь через реальный туннель.
  /// Без переключения входа — годится для фона и для кнопки «Проверить соединение».
  Future<DiagnosticsReport> checkCurrent() async {
    final started = env.clock();
    final watch = Stopwatch()..start();
    final stages = <StageResult>[];
    final entries = <EntryResult>[];

    stages.add(await env.checkNetwork());
    if (env.cancelled()) {
      return _report(started, watch, stages, entries,
          cancelled: true, cancelReason: _reason());
    }
    stages.add(await env.checkSubscription());
    if (env.cancelled()) {
      return _report(started, watch, stages, entries,
          cancelled: true, cancelReason: _reason());
    }
    stages.add(await env.checkCore());
    if (env.cancelled()) {
      return _report(started, watch, stages, entries,
          cancelled: true, cancelReason: _reason());
    }

    final current = env.currentEntry();
    if (current != null && stages.every((s) => s.ok)) {
      entries.add(await _probeEntry(current, watch));
    }
    return _report(started, watch, stages, entries,
        cancelled: env.cancelled(), cancelReason: _reason());
  }

  /// Активный тест переключения: каждый вход отдельно через реальный туннель,
  /// с замером восстановления. Только по нажатию пользователя (экран предупреждает
  /// о кратком перерыве). Исходный вход возвращается в конце — рабочие профили
  /// сохраняются.
  Future<DiagnosticsReport> checkAllEntries() async {
    final started = env.clock();
    final watch = Stopwatch()..start();
    final stages = <StageResult>[];
    final entries = <EntryResult>[];

    stages.add(await env.checkNetwork());
    stages.add(await env.checkSubscription());
    stages.add(await env.checkCore());
    if (env.cancelled() || !stages.every((s) => s.ok)) {
      return _report(started, watch, stages, entries,
          switchTested: true,
          cancelled: env.cancelled(),
          cancelReason: _reason());
    }

    final candidates = env.entries().take(budget.maxEntries).toList();
    final original = env.currentEntry();
    try {
      for (final candidate in candidates) {
        if (env.cancelled()) break;
        if (watch.elapsed >= budget.total) break;
        final switchWatch = Stopwatch()..start();
        await env.switchTo(candidate);
        if (env.cancelled()) break;
        final result = await _probeEntry(candidate, watch);
        entries.add(
          EntryResult(
            entry: result.entry,
            verdict: result.verdict,
            stage: DiagStage.switchEntry,
            controls: result.controls,
            elapsed: result.elapsed,
            recovery: switchWatch.elapsed,
            note: result.note,
          ),
        );
      }
    } finally {
      // Возврат исходного входа даже при отказе или отмене: рабочий профиль
      // пользователя не должен остаться переключённым.
      if (original != null && !env.cancelled()) {
        await env.switchTo(original);
      }
      await env.restore();
    }
    return _report(started, watch, stages, entries,
        switchTested: true,
        cancelled: env.cancelled(),
        cancelReason: _reason());
  }

  /// Путь одного входа через реальный туннель по двум контрольным адресам.
  Future<EntryResult> _probeEntry(EntryCandidate entry, Stopwatch watch) async {
    final entryWatch = Stopwatch()..start();
    final controls = <String, int?>{};

    // Нет входа через ядро (например, локальный вход socks): честно проверить
    // туннель нельзя — «не удалось проверить», прямой обход не подменяет туннель.
    if (!env.reachesCore()) {
      return EntryResult(
        entry: entry,
        verdict: DiagVerdict.unknown,
        stage: DiagStage.path,
        controls: controls,
        elapsed: entryWatch.elapsed,
        note: 'нет входа через ядро: проверить туннель нельзя',
      );
    }

    var passed = 0;
    for (final control in _controls) {
      if (env.cancelled() || watch.elapsed >= budget.total) break;
      final outcome = await env.probe(
        control.uri,
        viaTunnel: true,
        timeout: budget.probeTimeout,
      );
      controls[control.label] = outcome.statusCode;
      if (control.matches(outcome.statusCode)) passed++;
    }

    if (env.cancelled()) {
      final reason = _reason();
      return EntryResult(
        entry: entry,
        verdict: DiagVerdict.unknown,
        stage: DiagStage.path,
        controls: controls,
        elapsed: entryWatch.elapsed,
        note: reason == null
            ? 'проверка прервана'
            : 'проверка прервана: ${cancelReasonName(reason)}',
      );
    }

    // Ожидаемый ответ хотя бы от одного независимого адреса через туннель —
    // путь работает. Отказ одного контрольного сайта отказом туннеля не считается.
    if (passed > 0) {
      return EntryResult(
        entry: entry,
        verdict: DiagVerdict.works,
        stage: DiagStage.path,
        controls: controls,
        elapsed: entryWatch.elapsed,
        note: passed < _controls.length ? 'один контрольный адрес не ответил' : '',
      );
    }

    // Ни один контрольный адрес не дал ожидаемого ответа через туннель. Прежде
    // чем объявить отказ туннеля, проверяем сами адреса напрямую: если они тоже
    // недоступны, отказ туннеля не доказан — «не удалось проверить».
    var directReachable = false;
    for (final control in _controls) {
      if (env.cancelled() || watch.elapsed >= budget.total) break;
      final direct = await env.probe(
        control.uri,
        viaTunnel: false,
        timeout: budget.probeTimeout,
      );
      if (control.matches(direct.statusCode)) {
        directReachable = true;
        break;
      }
    }

    if (directReachable) {
      return EntryResult(
        entry: entry,
        verdict: DiagVerdict.failureConfirmed,
        stage: DiagStage.path,
        controls: controls,
        elapsed: entryWatch.elapsed,
        note: 'контрольный адрес доступен напрямую, через туннель — нет',
      );
    }
    return EntryResult(
      entry: entry,
      verdict: DiagVerdict.unknown,
      stage: DiagStage.path,
      controls: controls,
      elapsed: entryWatch.elapsed,
      note: 'контрольные адреса недоступны и напрямую: отказ туннеля не доказан',
    );
  }

  DiagnosticsReport _report(
    DateTime started,
    Stopwatch watch,
    List<StageResult> stages,
    List<EntryResult> entries, {
    bool switchTested = false,
    bool cancelled = false,
    DiagCancelReason? cancelReason,
  }) {
    watch.stop();
    return DiagnosticsReport(
      facts: env.facts(),
      stages: stages,
      entries: entries,
      verdict: _overall(stages, entries, cancelled),
      startedAt: started,
      totalElapsed: watch.elapsed,
      switchTested: switchTested,
      cancelled: cancelled,
      cancelReason: cancelled ? cancelReason : null,
    );
  }

  /// Общий итог: отказ этапа — подтверждённый отказ; иначе по входам.
  DiagVerdict _overall(
    List<StageResult> stages,
    List<EntryResult> entries,
    bool cancelled,
  ) {
    if (cancelled) return DiagVerdict.unknown;
    if (stages.any((s) => !s.ok)) return DiagVerdict.failureConfirmed;
    if (entries.isEmpty) return DiagVerdict.unknown;
    if (entries.any((e) => e.verdict == DiagVerdict.works)) return DiagVerdict.works;
    if (entries.every((e) => e.verdict == DiagVerdict.failureConfirmed)) {
      return DiagVerdict.failureConfirmed;
    }
    return DiagVerdict.unknown;
  }
}