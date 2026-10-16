import 'dart:convert';

import 'package:grpc/grpc.dart';

import 'traffic.dart';

/// Счётчики трафика ядра Xray на десктопе.
///
/// Туннельного адаптера на Windows нет: ядро стоит локальным http/socks
/// прокси, а журнал доступа Xray 26.3.27 байтов не содержит. Единственный
/// точный источник — gRPC StatsService (QueryStats) со счётчиками
/// `inbound>>>tag>>>traffic>>>uplink|downlink`, которые ядро ведёт само.
///
/// Сообщения QueryStats кодируются и разбираются вручную: протокол-буфер
/// для двух полей проще сгенерированных заглушек, а зависимость `protobuf`
/// тогда не нужна.
class CoreStats {
  CoreStats._();

  /// Подсказка всех счётчиков трафика: имя счётчика содержит этот фрагмент.
  static const _pattern = '>>>traffic>>>';

  /// Добавляет в конфиг ядра API статистики: сам API-вход на петле,
  /// службу Stats и учёт байтов по входам. Файл пользователя не меняется —
  /// правится копия, которая пишется в рабочую папку.
  static String injectStatsApi(String userJson, int apiPort) {
    final decoded = jsonDecode(userJson);
    if (decoded is! Map) {
      throw const FormatException('Конфиг должен быть JSON-объектом');
    }
    final map = Map<String, dynamic>.from(decoded.cast<String, dynamic>());

    // Живая проверка на Xray 26.3.27 (16.10.2026): служба регистрируется
    // только под именем `StatsService` — вариант `Stats` из старых конфигов
    // ядро принимает, но gRPC отвечает UNIMPLEMENTED. Отдельный inbound с
    // protocol `api` больше не существует: адрес API задаётся полем `listen`
    // в формате `host:port` внутри самого объекта `api`.
    map['api'] = {
      'tag': 'api',
      'services': ['StatsService'],
      'listen': '127.0.0.1:$apiPort',
    };
    map['stats'] = <String, dynamic>{};

    final policy = map['policy'] is Map
        ? Map<String, dynamic>.from((map['policy'] as Map).cast<String, dynamic>())
        : <String, dynamic>{};
    final system = policy['system'] is Map
        ? Map<String, dynamic>.from((policy['system'] as Map).cast<String, dynamic>())
        : <String, dynamic>{};
    system['statsInboundUplink'] = true;
    system['statsInboundDownlink'] = true;
    policy['system'] = system;
    map['policy'] = policy;

    return jsonEncode(map);
  }

  /// Порт API статистики запущенного ядра. Ставит [DesktopCore], снимает он же
  /// при остановке: опрос трафика работает только между этими событиями.
  static int? apiPort;

  /// Один опрос: байты, которые ядро насчитало с прошлого запроса
  /// (`reset: true` обнуляет счётчики — сумма сессии копится в клиенте).
  ///
  /// Возвращает (uplink, downlink); null, если ядро ещё не подняло API.
  static Future<(int up, int down)?> queryDelta(int port) async {
    final channel = ClientChannel(
      '127.0.0.1',
      port: port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    try {
      final method = ClientMethod<List<int>, List<int>>(
        '/xray.app.stats.command.StatsService/QueryStats',
        (request) => request,
        (response) => response,
      );
      final call = channel.createCall(
        method,
        Stream.value(_encodeRequest(_pattern, reset: true)),
        CallOptions(timeout: const Duration(seconds: 3)),
      );
      var up = 0;
      var down = 0;
      var seen = false;
      await for (final response in call.response) {
        for (final (name, value) in _decodeResponse(response)) {
          seen = true;
          if (name.endsWith('uplink')) {
            up += value;
          } else if (name.endsWith('downlink')) {
            down += value;
          }
        }
      }
      return seen ? (up, down) : null;
    } on GrpcError {
      return null;
    } on Exception {
      return null;
    } finally {
      await channel.shutdown();
    }
  }

  // --- Ручной протокол-буфер ---------------------------------------------

  /// QueryStatsRequest { string name = 1; bool reset = 2; }
  static List<int> _encodeRequest(String name, {required bool reset}) => [
    0x0A,
    ..._varint(name.length),
    ...utf8.encode(name),
    0x10,
    if (reset) 1 else 0,
  ];

  /// QueryStatsResponse { repeated Stat stat = 1; },
  /// Stat { string name = 1; int64 value = 2; }
  static Iterable<(String, int)> _decodeResponse(List<int> bytes) sync* {
    final reader = _Reader(bytes);
    while (reader.hasMore) {
      final tag = reader.readVarint();
      if (tag == 0x0A) {
        final stat = _Reader(reader.readBytes());
        var name = '';
        var value = 0;
        while (stat.hasMore) {
          final field = stat.readVarint();
          if (field == 0x0A) {
            name = utf8.decode(stat.readBytes());
          } else if (field == 0x10) {
            value = stat.readVarint();
          } else {
            stat.skip(field & 0x7);
          }
        }
        yield (name, value);
      } else {
        reader.skip(tag & 0x7);
      }
    }
  }

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>>= 7;
    }
    out.add(v & 0x7F);
    return out;
  }
}

class _Reader {
  _Reader(this.bytes);

  final List<int> bytes;
  int offset = 0;

  bool get hasMore => offset < bytes.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (offset < bytes.length) {
      final byte = bytes[offset++];
      result |= (byte & 0x7F) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
    return result;
  }

  List<int> readBytes() {
    final length = readVarint();
    final end = offset + length;
    if (end > bytes.length) {
      throw const FormatException('короткое сообщение протокола-буфер');
    }
    final slice = bytes.sublist(offset, end);
    offset = end;
    return slice;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 2:
        readBytes();
      case 5:
        offset += 4;
      case 1:
        offset += 8;
      default:
        offset = bytes.length;
    }
  }
}

/// Опрос трафика раз в секунду: зеркало таймера TunnelService.kt на Windows.
///
/// Скорость — дельта байтов на дельту секунд, сессия — сумма дельт с момента
/// поднятия туннеля. Ошибка опроса не роняет туннель: снимок просто не
/// обновляется.
class TrafficPoller {
  TrafficPoller({Duration interval = const Duration(seconds: 1)})
    : _interval = interval;

  final Duration _interval;
  DateTime? _lastTick;
  int _totalUp = 0;
  int _totalDown = 0;

  /// Раз в интервал спрашивает ядро и отдаёт снимок; null — счётчики молчат.
  Stream<TrafficSnapshot> watch() async* {
    _lastTick = DateTime.now();
    while (true) {
      await Future<void>.delayed(_interval);
      final port = CoreStats.apiPort;
      if (port == null) continue;
      final now = DateTime.now();
      final elapsed = now.difference(_lastTick ?? now).inMicroseconds / 1e6;
      _lastTick = now;
      final delta = await CoreStats.queryDelta(port);
      if (delta == null) continue;
      _totalUp += delta.$1;
      _totalDown += delta.$2;
      final seconds = elapsed > 0 ? elapsed : 1.0;
      yield TrafficSnapshot(
        upSpeed: delta.$1 / seconds,
        downSpeed: delta.$2 / seconds,
        totalUp: _totalUp,
        totalDown: _totalDown,
      );
    }
  }
}
