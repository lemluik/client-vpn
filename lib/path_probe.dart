import 'dart:async';
import 'dart:io';

import 'app_proxy.dart';

/// Что известно о пути до узла (Д2-25).
///
/// `unknown` — проверить нельзя: собственный трафик приложения не идёт через
/// ядро (в конфиге нет локального http-входа), честного ответа нет, и экран в
/// этом случае не имеет права писать «Защищено».
enum PathState { unknown, checking, live, dead }

/// Одна проба пути: true — байты дошли до узла и вернулись.
typedef PathAttempt = Future<bool> Function(Uri endpoint);

/// Срок одной пробы. Взят с запасом против рукопожатия Reality на живых
/// входах (замер 22.10.2026: медиана рукопожатия 1,9 мс, хвосты до сотен мс),
/// чтобы медленный, но живой путь не выглядел мёртвым.
const Duration probeTimeout = Duration(seconds: 6);

/// Собственный трафик приложения сейчас идёт через ядро?
bool appReachesCore() => AppProxy.reachesCore;

/// Проба по HTTP собственным трафиком приложения.
///
/// Запрос уходит в локальный вход ядра ([AppProxy.findProxy]), поэтому
/// завершившийся обмен означает, что путь клиент → узел → интернет работает.
/// Код ответа не важен: наши входы отвечают 403 на проверку адреса, и это
/// живой путь. Важен сам факт, что ответ пришёл.
///
/// Проба следует правилам маршрутизации пользователя: если точка проб попала
/// в правило «напрямую», проверяется не туннель, а связь устройства. Точка по
/// умолчанию (`generate_204`) под такие правила не попадает.
Future<bool> httpAttempt(Uri endpoint) async {
  final client = HttpClient()
    ..findProxy = AppProxy.findProxy
    ..connectionTimeout = probeTimeout;
  try {
    final request = await client.getUrl(endpoint).timeout(probeTimeout);
    final response = await request.close().timeout(probeTimeout);
    await response.drain<void>();
    return true;
  } on Object {
    // Проба работает фоном всю сессию: ни отказ узла, ни битый адрес точки
    // проб не должны ронять приложение.
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Проверка пути до узла, пока туннель поднят (Д2-25).
///
/// Без неё «Защищено» означало только «ядро запущено»: служба Android
/// публикует статус сразу после подъёма туннеля, и экран писал о защите и при
/// мёртвом узле, и при отсутствии интернета вовсе.
///
/// Провал одной пробы живой путь не отменяет: сеть моргает, а надпись не
/// должна мигать вместе с ней. Мёртвым путь становится после
/// [failuresBeforeDead] провалов подряд.
class PathProbe {
  PathProbe({
    PathAttempt attempt = httpAttempt,
    bool Function() reachesCore = appReachesCore,
    Duration retry = const Duration(seconds: 3),
    Duration deadRetry = const Duration(seconds: 10),
    Duration idle = const Duration(seconds: 30),
    int failuresBeforeDead = 2,
  }) : _attempt = attempt,
       _reachesCore = reachesCore,
       _retry = retry,
       _deadRetry = deadRetry,
       _idle = idle,
       _failuresBeforeDead = failuresBeforeDead;

  final PathAttempt _attempt;
  final bool Function() _reachesCore;
  final Duration _retry;
  final Duration _deadRetry;
  final Duration _idle;
  final int _failuresBeforeDead;

  final StreamController<PathState> _changes =
      StreamController<PathState>.broadcast();

  Timer? _timer;
  bool _active = false;
  int _run = 0;
  int _failures = 0;
  PathState _state = PathState.unknown;

  PathState get state => _state;

  /// Проверка идёт. Не путать с наличием таймера: запрос может быть в пути,
  /// и повторный [start] в этот момент сбросил бы счёт провалов.
  bool get isRunning => _active;

  Stream<PathState> get changes => _changes.stream;

  /// Начинает проверять путь. Повторный вызов начинает проверку заново — так
  /// состояние сбрасывается при смене подключения и точки проб.
  void start(Uri endpoint) {
    stop();
    if (!_reachesCore()) {
      _set(PathState.unknown);
      return;
    }
    _run++;
    _active = true;
    _failures = 0;
    _set(PathState.checking);
    final run = _run;
    _timer = Timer(Duration.zero, () => _tick(run, endpoint));
  }

  /// Снимает проверку: туннель опущен или приложение закрывается.
  void stop() {
    _run++;
    _active = false;
    _timer?.cancel();
    _timer = null;
    _failures = 0;
    _set(PathState.unknown);
  }

  void dispose() {
    stop();
    _changes.close();
  }

  Future<void> _tick(int run, Uri endpoint) async {
    _timer = null;
    final alive = await _attempt(endpoint);
    // Запрос мог пережить остановку или перезапуск пробы: ответ прежнего
    // захода состояние нового не определяет.
    if (run != _run) return;

    if (alive) {
      _failures = 0;
      _set(PathState.live);
    } else {
      _failures++;
      if (_failures >= _failuresBeforeDead) _set(PathState.dead);
    }
    _timer = Timer(_interval(), () => _tick(run, endpoint));
  }

  /// Пауза до следующей пробы: живой путь проверяется редко, сомнительный и
  /// мёртвый — часто, чтобы возвращение связи пользователь увидел сразу.
  Duration _interval() {
    if (_state == PathState.dead) return _deadRetry;
    if (_state != PathState.live || _failures > 0) return _retry;
    return _idle;
  }

  void _set(PathState value) {
    if (_state == value) return;
    _state = value;
    if (!_changes.isClosed) _changes.add(value);
  }
}
