import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Один этап одной попытки пробы: докуда дошла попытка и сколько заняла.
/// Имена фиксированы: `proxy` — поиск локального входа ядра, `tcp` —
/// соединение, `tls` — рукопожатие (для http не требуется), `http` — обмен,
/// `deadline` — общий срок пробы истёк.
class ProbeStage {
  const ProbeStage({
    required this.name,
    required this.ok,
    this.elapsed = Duration.zero,
    this.errorCode,
    this.note = '',
  });

  final String name;
  final bool ok;
  final Duration elapsed;

  /// Код ошибки ОС при отказе (например, 10061 — соединение отклонено).
  final int? errorCode;

  /// Короткое пояснение без адресов и ключей.
  final String note;
}

/// Результат одной пробы контрольного адреса.
class ProbeOutcome {
  const ProbeOutcome({
    this.statusCode,
    this.failure = ProbeFailure.none,
    this.elapsed = Duration.zero,
    this.trace = const [],
  });

  /// Код ответа, если обмен состоялся; null — ответа не было.
  final int? statusCode;
  final ProbeFailure failure;
  final Duration elapsed;

  /// Этапы попытки в порядке прохождения. Пусто у проб, которые не
  /// раскладываются на этапы (внедрённые окружения испытаний).
  final List<ProbeStage> trace;

  /// Ответ пришёл (код любой). Сам по себе успехом туннеля не считается:
  /// успех — только ожидаемый код, и только через туннель.
  bool get responded => statusCode != null;
}

/// Одна попытка пробы с контекстом момента: состояние ядра, тип сети и
/// обезличенный отпечаток конфига. Контрольный адрес назван меткой (A/B),
/// сам адрес в отчёт не попадает.
class ProbeAttempt {
  const ProbeAttempt({
    required this.label,
    required this.viaTunnel,
    required this.outcome,
    this.coreState = '',
    this.networkType = '',
    this.configFingerprint,
  });

  final String label;
  final bool viaTunnel;
  final ProbeOutcome outcome;

  /// Состояние ядра на момент попытки ('работает', 'поднимается', 'остановлено').
  final String coreState;

  /// Тип сети на момент попытки; смена сети между попытками видна в отчёте.
  final String networkType;

  /// Первые символы SHA-256 действующего конфига: сверить конфигурации между
  /// отчётами можно, содержимое (ключи, адреса) из отпечатка не получить.
  final String? configFingerprint;
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

/// Настоящая проба собственным трафиком приложения, разложенная на этапы:
/// поиск локального входа ядра → TCP-соединение → TLS (для https) → HTTP-обмен.
/// Каждый этап пишется в [ProbeOutcome.trace] с длительностью и кодом ошибки,
/// чтобы по отчёту было видно, докуда дошла попытка, а не только «не прошла».
///
/// Весь обмен ограничен общим сроком [timeout] (Ф5): сервер, приславший
/// заголовки и не завершающий тело, не имеет права повесить диагностику.
Future<ProbeOutcome> tunnelControlProbe(
  Uri endpoint, {
  required bool viaTunnel,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final watch = Stopwatch()..start();
  final trace = <ProbeStage>[];
  Socket? opened;
  final exchange = _stagedExchange(
    endpoint,
    viaTunnel,
    trace,
    (socket) => opened = socket,
  );
  try {
    final code = await exchange.timeout(timeout);
    return ProbeOutcome(
      statusCode: code,
      elapsed: watch.elapsed,
      trace: List.of(trace),
    );
  } on TimeoutException {
    // Общий срок истёк: сокет обрывается, поздний обмен не продолжается.
    opened?.destroy();
    unawaited(exchange.catchError((Object _) => 0));
    trace.add(ProbeStage(
      name: 'deadline',
      ok: false,
      elapsed: watch.elapsed,
      note: 'общий срок пробы истёк',
    ));
    return ProbeOutcome(
      failure: ProbeFailure.timeout,
      elapsed: watch.elapsed,
      trace: List.of(trace),
    );
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
    return ProbeOutcome(
      failure: failure,
      elapsed: watch.elapsed,
      trace: List.of(trace),
    );
  } on HandshakeException {
    return ProbeOutcome(
      failure: ProbeFailure.tls,
      elapsed: watch.elapsed,
      trace: List.of(trace),
    );
  } on HttpException {
    return ProbeOutcome(
      failure: ProbeFailure.http,
      elapsed: watch.elapsed,
      trace: List.of(trace),
    );
  } on Object {
    return ProbeOutcome(
      failure: ProbeFailure.other,
      elapsed: watch.elapsed,
      trace: List.of(trace),
    );
  }
}

/// Обмен по этапам. Ошибка этапа записывается в трассу и пробрасывается:
/// класс отказа определяет вызывающий по типу исключения.
Future<int> _stagedExchange(
  Uri endpoint,
  bool viaTunnel,
  List<ProbeStage> trace,
  void Function(Socket) onSocket,
) async {
  // Этап 1: поиск локального входа ядра.
  final proxyWatch = Stopwatch()..start();
  final proxy = viaTunnel ? AppProxy.findProxy(endpoint) : 'DIRECT';
  String? proxyHost;
  var proxyPort = 0;
  if (proxy.startsWith('PROXY ')) {
    final parts = proxy.substring(6).trim().split(':');
    proxyHost = parts.first;
    proxyPort = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
  }
  trace.add(ProbeStage(
    name: 'proxy',
    ok: true,
    elapsed: proxyWatch.elapsed,
    note: !viaTunnel
        ? 'напрямую, мимо ядра'
        : proxyHost == null
            ? 'локального http-входа нет: запрос идёт напрямую'
            : 'локальный http-вход, порт $proxyPort',
  ));

  // Этап 2: TCP-соединение — к локальному прокси, если он есть, иначе к цели.
  final tcpWatch = Stopwatch()..start();
  final Socket socket;
  try {
    socket = await Socket.connect(
      proxyHost ?? endpoint.host,
      proxyHost != null ? proxyPort : endpoint.port,
    );
  } on SocketException catch (error) {
    trace.add(ProbeStage(
      name: 'tcp',
      ok: false,
      elapsed: tcpWatch.elapsed,
      errorCode: error.osError?.errorCode,
      note: 'соединение не установлено',
    ));
    rethrow;
  }
  onSocket(socket);
  trace.add(ProbeStage(
    name: 'tcp',
    ok: true,
    elapsed: tcpWatch.elapsed,
    note: proxyHost != null
        ? 'соединение с локальным прокси'
        : 'соединение с целью',
  ));

  try {
    Socket channel = socket;
    // Этап 3: TLS. Контрольные адреса по умолчанию — http: проба проверяет
    // факт обмена, рукопожатие не требуется (см. defaultControlEndpoints).
    final tlsWatch = Stopwatch()..start();
    if (endpoint.scheme == 'https') {
      try {
        if (proxyHost != null) await _connectTunnel(socket, endpoint);
        channel = await SecureSocket.secure(socket, host: endpoint.host);
        trace.add(ProbeStage(
          name: 'tls',
          ok: true,
          elapsed: tlsWatch.elapsed,
          note: 'рукопожатие завершено',
        ));
      } on Object catch (error) {
        trace.add(ProbeStage(
          name: 'tls',
          ok: false,
          elapsed: tlsWatch.elapsed,
          errorCode: error is SocketException ? error.osError?.errorCode : null,
          note: 'рукопожатие не состоялось',
        ));
        rethrow;
      }
    } else {
      trace.add(ProbeStage(
        name: 'tls',
        ok: true,
        elapsed: tlsWatch.elapsed,
        note: 'не требуется: схема http',
      ));
    }

    // Этап 4: HTTP-обмен.
    final httpWatch = Stopwatch()..start();
    try {
      final code = await _httpExchange(
        channel,
        endpoint,
        viaProxy: proxyHost != null && endpoint.scheme != 'https',
      );
      trace.add(ProbeStage(
        name: 'http',
        ok: true,
        elapsed: httpWatch.elapsed,
        note: 'код ответа $code',
      ));
      return code;
    } on Object catch (error) {
      trace.add(ProbeStage(
        name: 'http',
        ok: false,
        elapsed: httpWatch.elapsed,
        errorCode: error is SocketException ? error.osError?.errorCode : null,
        note: 'обмен не состоялся',
      ));
      rethrow;
    }
  } finally {
    socket.destroy();
  }
}

/// CONNECT для https через http-прокси: прокси открывает сквозной канал.
Future<void> _connectTunnel(Socket socket, Uri endpoint) async {
  final authority = '${endpoint.host}:${endpoint.port}';
  socket.write('CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n');
  await socket.flush();
  final head = await _readHead(socket);
  final line = head.split('\r\n').first;
  final match = RegExp(r'^HTTP/\d\.\d (\d{3})').firstMatch(line);
  if (match == null || match.group(1) != '200') {
    throw HttpException(
      'прокси не открыл канал: ${match?.group(1) ?? 'нет ответа'}',
    );
  }
}

/// Заголовки ответа до пустой строки. Данные после заголовков не читаются:
/// для CONNECT они принадлежат уже TLS-каналу.
Future<String> _readHead(Socket socket) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in socket) {
    bytes.add(chunk);
    final data = bytes.toBytes();
    final end = _headEnd(data);
    if (end >= 0) {
      if (data.length > end + 4) {
        throw const HttpException('прокси прислал данные после ответа CONNECT');
      }
      return utf8.decode(data.sublist(0, end), allowMalformed: true);
    }
    if (data.length > probeMaxBodyBytes) {
      throw const HttpException('заголовки ответа слишком велики');
    }
  }
  throw const HttpException('соединение закрыто без ответа');
}

/// GET и чтение ответа с пределом тела. Через http-прокси запрос идёт в
/// абсолютной форме (иначе прокси не знает цель), напрямую — в обычной.
Future<int> _httpExchange(
  Socket socket,
  Uri endpoint, {
  required bool viaProxy,
}) async {
  final path = endpoint.path.isEmpty ? '/' : endpoint.path;
  final query = endpoint.hasQuery ? '?${endpoint.query}' : '';
  final target = viaProxy
      ? Uri(
          scheme: endpoint.scheme,
          host: endpoint.host,
          port: endpoint.port,
          path: path,
          query: endpoint.hasQuery ? endpoint.query : null,
        ).toString()
      : '$path$query';
  socket.write(
    'GET $target HTTP/1.1\r\n'
    'Host: ${endpoint.authority}\r\n'
    'Connection: close\r\n'
    'Accept: */*\r\n'
    '\r\n',
  );
  await socket.flush();

  final bytes = BytesBuilder(copy: false);
  var headEnd = -1;
  var code = 0;
  await for (final chunk in socket) {
    bytes.add(chunk);
    if (headEnd < 0) {
      final data = bytes.toBytes();
      headEnd = _headEnd(data);
      if (headEnd >= 0) {
        final head = utf8.decode(data.sublist(0, headEnd), allowMalformed: true);
        final line = head.split('\r\n').first;
        final match = RegExp(r'^HTTP/\d\.\d (\d{3})').firstMatch(line);
        if (match == null) {
          throw const HttpException('битая строка статуса ответа');
        }
        code = int.parse(match.group(1)!);
      } else if (data.length > probeMaxBodyBytes) {
        throw const HttpException('заголовки ответа слишком велики');
      }
    }
    // Тело читаем с пределом и обрываем: диагностика не должна тянуть мегабайты.
    if (headEnd >= 0 && bytes.length - headEnd - 4 >= probeMaxBodyBytes) break;
  }
  if (headEnd < 0) throw const HttpException('соединение закрыто без ответа');
  return code;
}

/// Позиция пустой строки (\r\n\r\n) в накопленных байтах; -1 — ещё нет.
int _headEnd(List<int> data) {
  for (var i = 0; i + 3 < data.length; i++) {
    if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// Имя класса отказа для отчёта.
String failureName(ProbeFailure failure) => switch (failure) {
  ProbeFailure.none => 'нет',
  ProbeFailure.refused => 'соединение отклонено',
  ProbeFailure.timeout => 'таймаут',
  ProbeFailure.dns => 'DNS',
  ProbeFailure.tls => 'TLS',
  ProbeFailure.http => 'HTTP',
  ProbeFailure.other => 'иное',
};

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

/// Наблюдение маршрута для входа: фактическая метка исходящего соединения,
/// которое ядро использовало для обмена (null — определить нельзя), и метки
/// настроенного региона. Внедряется через [DiagnosticsEnv.observeRoute].
typedef RouteObservation = ({String? actual, List<String> candidates});

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
    this.attempts = const [],
    this.networkChanged = false,
    this.actualRoute,
    this.routeCandidates = const [],
  });

  /// Настроенный вход — регион, который выбрал пользователь. Это не обязательно
  /// тот узел, через который прошла проба: внутри региона узел выбирает
  /// балансировщик ядра на ходу.
  final EntryCandidate entry;
  final DiagVerdict verdict;
  final DiagStage stage;

  /// Наблюдённый код по каждому контрольному адресу (метка → код или null).
  final Map<String, int?> controls;
  final Duration elapsed;

  /// Длительность восстановления после переключения на этот вход.
  final Duration? recovery;
  final String note;

  /// Попытки пробы с этапами и контекстом момента (ядро, сеть, конфиг).
  final List<ProbeAttempt> attempts;

  /// Тип сети менялся между попытками: отказ может быть следствием смены сети.
  final bool networkChanged;
  /// Фактический маршрут этой пробы: метка исходящего соединения, которое ядро
  /// выбрало для обмена. null — «не установлен»: клиент не имеет обратной связи
  /// о выбранном балансировщиком узле, и подставлять первый outbound нельзя.
  final String? actualRoute;

  /// Метки исходящих соединений настроенного региона (cvpn-proxy, cvpn-proxy-2…).
  /// Порядковые, без адресов и ключей: по ним поддержка сопоставляет пробу с
  /// серверным журналом, не раскрывая адрес узла в отчёте.
  final List<String> routeCandidates;
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
    this.budgetExceeded = false,
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

  /// Общий срок диагностики исчерпан: отчёт неполный, но проверка завершена
  /// и блокировку восстановления сняла.
  final bool budgetExceeded;

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
    if (budgetExceeded) {
      buffer.writeln('Срок проверки исчерпан: отчёт неполный');
    }
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
        'Настроенный вход «${entry.entry.label}»: ${verdictName(entry.verdict)} '
        '(${entry.elapsed.inMilliseconds} мс)',
      );
      // Фактический маршрут отделён от настроенного: если ядро не сообщило,
      // какой узел выбрал балансировщик, пишем «не установлен», а не первый.
      buffer.writeln(
        '  фактический маршрут: ${entry.actualRoute ?? 'не установлен'}',
      );
      if (entry.routeCandidates.isNotEmpty) {
        buffer.writeln(
          '  метки маршрутов региона: ${entry.routeCandidates.join(', ')}',
        );
      }
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
      for (final attempt in entry.attempts) {
        final outcome = attempt.outcome;
        buffer.writeln(
          '  попытка ${attempt.label} '
          '(${attempt.viaTunnel ? 'через туннель' : 'напрямую'}): '
          '${outcome.statusCode ?? 'нет ответа'}'
          '${outcome.failure != ProbeFailure.none ? ', отказ: ${failureName(outcome.failure)}' : ''} '
          '(${outcome.elapsed.inMilliseconds} мс)',
        );
        for (final stage in outcome.trace) {
          buffer.writeln(
            '    ${stage.name}: ${stage.ok ? 'ок' : 'отказ'} '
            '(${stage.elapsed.inMilliseconds} мс)'
            '${stage.errorCode != null ? ', код ${stage.errorCode}' : ''}'
            '${stage.note.isEmpty ? '' : ' — ${stage.note}'}',
          );
        }
        final context = [
          if (attempt.coreState.isNotEmpty) 'ядро: ${attempt.coreState}',
          if (attempt.networkType.isNotEmpty) 'сеть: ${attempt.networkType}',
          if (attempt.configFingerprint != null)
            'конфиг: ${attempt.configFingerprint}',
        ];
        if (context.isNotEmpty) buffer.writeln('    ${context.join('; ')}');
      }
      if (entry.networkChanged) {
        buffer.writeln('  сеть менялась во время проверки');
      }
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
    this.coreState,
    this.configFingerprint,
    this.clock = DateTime.now,
    this.controlEndpoints,
    this.observeRoute,
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

  /// Состояние ядра на момент попытки. Не задано — в отчёте не пишется.
  final String Function()? coreState;

  /// Обезличенный отпечаток действующего конфига (префикс хеша). Не задан —
  /// в отчёте не пишется; само содержимое конфига сюда не передаётся.
  final String? Function()? configFingerprint;
  final DateTime Function() clock;
  final List<ControlEndpoint>? controlEndpoints;

  /// Маршрут входа на момент пробы: фактическая метка исходящего соединения
  /// (null — не установлена) и метки-кандидаты настроенного региона. Null —
  /// наблюдателя нет, фактический маршрут остаётся «не установлен».
  final RouteObservation Function(EntryCandidate entry)? observeRoute;
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

  bool _expired(Stopwatch watch) => watch.elapsed >= budget.total;

  /// Проба с учётом общего срока: ожидание одной попытки ограничено остатком
  /// бюджета, а проба, проигнорировавшая собственный таймаут, обрывается
  /// сверху жёстким сроком. Диагностика не имеет права задерживать
  /// восстановление бесконечно: после завершения блокировка снимается.
  Future<ProbeOutcome> _boundedProbe(
    ControlEndpoint control, {
    required bool viaTunnel,
    required Stopwatch watch,
  }) {
    final remaining = budget.total - watch.elapsed;
    if (remaining <= Duration.zero) {
      return Future.value(const ProbeOutcome(failure: ProbeFailure.timeout));
    }
    final limit = remaining < budget.probeTimeout ? remaining : budget.probeTimeout;
    return env
        .probe(control.uri, viaTunnel: viaTunnel, timeout: limit)
        .timeout(
          limit + const Duration(seconds: 1),
          onTimeout: () =>
              ProbeOutcome(failure: ProbeFailure.timeout, elapsed: limit),
        );
  }

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
    if (_expired(watch)) {
      return _report(started, watch, stages, entries, budgetExceeded: true);
    }
    stages.add(await env.checkSubscription());
    if (env.cancelled()) {
      return _report(started, watch, stages, entries,
          cancelled: true, cancelReason: _reason());
    }
    if (_expired(watch)) {
      return _report(started, watch, stages, entries, budgetExceeded: true);
    }
    stages.add(await env.checkCore());
    if (env.cancelled()) {
      return _report(started, watch, stages, entries,
          cancelled: true, cancelReason: _reason());
    }

    final current = env.currentEntry();
    if (current != null && stages.every((s) => s.ok) && !_expired(watch)) {
      entries.add(await _probeEntry(current, watch));
    }
    return _report(started, watch, stages, entries,
        cancelled: env.cancelled(),
        cancelReason: _reason(),
        budgetExceeded: _expired(watch));
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
            attempts: result.attempts,
            networkChanged: result.networkChanged,
            actualRoute: result.actualRoute,
            routeCandidates: result.routeCandidates,
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
        cancelReason: _reason(),
        budgetExceeded: _expired(watch));
  }

  /// Путь одного входа через реальный туннель по двум контрольным адресам.
  /// Каждая попытка записывается с этапами и контекстом момента (ядро, сеть,
  /// отпечаток конфига) — по отчёту видно, докуда дошла попытка.
  Future<EntryResult> _probeEntry(EntryCandidate entry, Stopwatch watch) async {
    final entryWatch = Stopwatch()..start();
    final controls = <String, int?>{};
    final attempts = <ProbeAttempt>[];
    final networks = <String>{};

    ProbeAttempt record(
      ControlEndpoint control,
      bool viaTunnel,
      ProbeOutcome outcome,
    ) {
      final network = env.facts().networkType;
      networks.add(network);
      final attempt = ProbeAttempt(
        label: viaTunnel ? control.label : '${control.label} напрямую',
        viaTunnel: viaTunnel,
        outcome: outcome,
        coreState: env.coreState?.call() ?? '',
        networkType: network,
        configFingerprint: env.configFingerprint?.call(),
      );
      attempts.add(attempt);
      return attempt;
    }
    // Маршрут снимается для этого входа на момент пробы. Без наблюдателя
    // фактический путь не установлен — первый outbound не подставляется.
    final route = env.observeRoute?.call(entry) ??
        const (actual: null, candidates: <String>[]);

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
        actualRoute: route.actual,
        routeCandidates: route.candidates,
      );
    }

    var passed = 0;
    for (final control in _controls) {
      if (env.cancelled() || _expired(watch)) break;
      final outcome = await _boundedProbe(control, viaTunnel: true, watch: watch);
      record(control, true, outcome);
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
        attempts: attempts,
        networkChanged: networks.length > 1,
        actualRoute: route.actual,
        routeCandidates: route.candidates,
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
        attempts: attempts,
        networkChanged: networks.length > 1,
        actualRoute: route.actual,
        routeCandidates: route.candidates,
      );
    }

    // Ни один контрольный адрес не дал ожидаемого ответа через туннель. Прежде
    // чем объявить отказ туннеля, проверяем сами адреса напрямую: если они тоже
    // недоступны, отказ туннеля не доказан — «не удалось проверить».
    var directReachable = false;
    for (final control in _controls) {
      if (env.cancelled() || _expired(watch)) break;
      final direct = await _boundedProbe(control, viaTunnel: false, watch: watch);
      record(control, false, direct);
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
        attempts: attempts,
        networkChanged: networks.length > 1,
        actualRoute: route.actual,
        routeCandidates: route.candidates,
      );
    }
    return EntryResult(
      entry: entry,
      verdict: DiagVerdict.unknown,
      stage: DiagStage.path,
      controls: controls,
      elapsed: entryWatch.elapsed,
      note: 'контрольные адреса недоступны и напрямую: отказ туннеля не доказан',
      attempts: attempts,
      networkChanged: networks.length > 1,
      actualRoute: route.actual,
      routeCandidates: route.candidates,
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
    bool budgetExceeded = false,
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
      budgetExceeded: budgetExceeded,
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