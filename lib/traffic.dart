/// Снимок трафика туннеля: скорость за последний замер и итог сессии.
///
/// Зеркало Android-уведомления из TunnelService.kt: те же две строки
/// («↑ скорость/с» и «За сессию: ↑ X · ↓ Y») и те же единицы
/// Б/КБ/МБ/ГБ с одним знаком после запятой.
class TrafficSnapshot {
  const TrafficSnapshot({
    required this.upSpeed,
    required this.downSpeed,
    required this.totalUp,
    required this.totalDown,
  });

  /// Скорость, байт/с: up — исходящий (upload), down — входящий (download).
  final double upSpeed;
  final double downSpeed;

  /// Итог сессии в байтах: считается с момента поднятия туннеля.
  final int totalUp;
  final int totalDown;
}

/// Байты в человекочитаемую строку: Б/КБ/МБ/ГБ, один знак после запятой
/// (у байтов знака нет — дробных байтов не бывает).
String formatBytes(num bytes) {
  if (bytes < 1024) return '${bytes.round()} Б';
  if (bytes < 1024 * 1024) return _one(bytes / 1024, 'КБ');
  if (bytes < 1024 * 1024 * 1024) return _one(bytes / (1024 * 1024), 'МБ');
  return _one(bytes / (1024 * 1024 * 1024), 'ГБ');
}

String _one(double value, String unit) =>
    '${value.toStringAsFixed(1)} $unit';
