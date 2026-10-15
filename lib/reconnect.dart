import 'dart:math';

/// Паузы перечитывания подписки при отказе (МК-5).
///
/// Числа взяты из `СПЕЦИФИКАЦИЯ_МУЛЬТИРЕГИОН.md` §5 («поведение при отказе:
/// экспоненциальная пауза 1 — 5 — 30 минут»), а не придуманы в клиенте.
const List<Duration> subscriptionPauses = [
  Duration(minutes: 1),
  Duration(minutes: 5),
  Duration(minutes: 30),
];

/// Интервал проб поднятого туннеля в состоянии «нет связи» (МК-5).
///
/// Тоже из спецификации мультирегиона: «пробы раз в 30 секунд и подсказкой
/// обновить подписку».
const Duration linkProbeInterval = Duration(seconds: 30);

/// Шаг лестницы переподключений: сколько раз подряд что-то пробовали.
class ReconnectPlan {
  ReconnectPlan({
    List<Duration> pauses = subscriptionPauses,
    this.probeInterval = linkProbeInterval,
  }) : _pauses = List.of(pauses);

  final List<Duration> _pauses;

  /// Интервал проб туннеля в состоянии сбоя. В испытаниях подменяется коротким.
  final Duration probeInterval;

  int _step = 0;

  /// Сколько пауз уже использовано.
  int get step => _step;

  /// Лестница исчерпана: дальше — только обычное обновление по интервалу
  /// провайдера, бесконечно подписку перечитывать нельзя.
  bool get exhausted => _step >= _pauses.length;

  /// Пауза перед следующим перечитыванием подписки.
  Duration nextPause() => _pauses[min(_step, _pauses.length - 1)];

  /// Использует паузу и возвращает её.
  Duration takePause() {
    final pause = nextPause();
    _step++;
    return pause;
  }

  /// Сброс после удачного подключения или действия пользователя.
  void reset() => _step = 0;
}
