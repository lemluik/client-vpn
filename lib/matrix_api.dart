/// Клиент Matrix по Client-Server API v3: только то, что нужно чату поддержки.
/// Сторонних SDK нет намеренно — Famedly и FluffyChat под AGPL, а наш код
/// распространяется под MPL-2.0.
///
/// Адрес узла приходит от провайдера или вводится пользователем: в этот файл
/// адреса наших узлов не вписываются (У-8).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Предел ожидания обычного запроса: и соединение, и чтение.
const Duration matrixTimeout = Duration(seconds: 20);

/// Сколько сервер держит long-poll `/sync`. Одно такое соединение на клиента.
const Duration matrixSyncWait = Duration(seconds: 25);

/// Предел тела ответа узла: история страницы сообщений заметно меньше.
const int maxMatrixBytes = 2 * 1024 * 1024;

/// Предел нашего тела: на узле nginx ограничивает запрос 1 MiB.
const int maxMatrixBodyBytes = 1024 * 1024;

const String _api = '/_matrix/client/v3';

/// Ответ узла: код и разобранный JSON (пустой, если JSON не читается).
class MatrixReply {
  const MatrixReply(this.status, this.json);

  final int status;
  final Map<String, dynamic> json;

  bool get ok => status >= 200 && status < 300;

  String get errcode => json['errcode'] is String ? json['errcode'] as String : '';

  bool get unknownToken => status == 401 || errcode == 'M_UNKNOWN_TOKEN';
}

/// Запрос к узлу. `wait` отдельно от URL, чтобы long-poll ждал дольше обычного.
class MatrixRequest {
  const MatrixRequest(this.method, this.url, {this.body, this.token, this.wait = matrixTimeout});

  final String method;
  final Uri url;
  final String? body;
  final String? token;
  final Duration wait;
}

/// Способ обмена с узлом. В испытаниях подменяется заглушкой: сеть не нужна,
/// а поведение на кодах 401/429/5xx проверяется напрямую.
typedef MatrixCaller = Future<MatrixReply> Function(MatrixRequest request);

/// Ошибка протокола: код и `errcode` узла. Адреса и токены сюда не попадают.
class MatrixException implements Exception {
  const MatrixException(this.status, this.errcode);

  final int status;
  final String errcode;

  bool get rateLimited => status == 429;
  bool get unknownToken => status == 401 || errcode == 'M_UNKNOWN_TOKEN';

  @override
  String toString() => 'Matrix $status ${errcode.isEmpty ? '' : errcode}'.trim();
}

/// Результат входа: токен остаётся в памяти клиента и уходит в защищённое
/// хранилище, полное имя учётки нужно, чтобы не показывать свои сообщения
/// как чужие.
class LoginResult {
  const LoginResult({
    required this.userId,
    required this.deviceId,
    required this.token,
  });

  final String userId;
  final String deviceId;
  final String token;
}

/// Один чат с одним узлом: адрес зафиксирован при входе, молча не переключается.
class MatrixClient {
  MatrixClient(this.homeserver, {
    String? token,
    MatrixCaller? call,
    Duration syncWait = matrixSyncWait,
  })  : _token = token,
        _call = call ?? sendMatrixRequest,
        _syncWait = syncWait;

  final String homeserver;
  final MatrixCaller _call;
  final Duration _syncWait;
  String? _token;

  String? get token => _token;
  bool get signedIn => _token != null;

  Uri _url(String path, [Map<String, String>? query]) {
    final uri = Uri.parse('$homeserver$path');
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Future<MatrixReply> _get(String method, Uri url, {String? body, Duration? wait}) async {
    final reply = await _call(MatrixRequest(method, url, body: body, token: _token, wait: wait ?? matrixTimeout));
    if (!reply.ok) throw MatrixException(reply.status, reply.errcode);
    return reply;
  }

  /// Проверяет, что по адресу действительно Matrix-узел. Токен не нужен.
  Future<List<String>> versions() async {
    final reply = await _get('GET', Uri.parse('$homeserver/_matrix/client/versions'));
    final list = reply.json['versions'];
    return list is List ? list.whereType<String>().toList() : const [];
  }

  /// Входит готовой учёткой: регистрация на узлах закрыта. Форма `identifier`
  /// измерена на пилоте — вариант `user_id` узел отвергает как `M_BAD_JSON`.
  Future<LoginResult> login(String user, String password) async {
    final payload = jsonEncode({
      'type': 'm.login.password',
      'user': user,
      'identifier': {'type': 'm.id.user', 'user': user},
      'password': password,
      'initial_device_display_name': 'client-vpn',
    });
    final MatrixReply reply;
    try {
      reply = await _get('POST', _url('$_api/login'), body: payload);
    } on MatrixException catch (error) {
      // Отказ входа приходит тем же 403, что и недоступная комната. Без этой
      // подмены интерфейс упрекал бы комнату в неверном пароле.
      if (error.status == 403) throw const MatrixException(403, 'M_LOGIN_REJECTED');
      rethrow;
    }
    final token = reply.json['access_token'];
    if (token is! String || token.isEmpty) {
      throw const MatrixException(502, 'M_MISSING_TOKEN');
    }
    _token = token;
    final device = reply.json['device_id'];
    final identity = reply.json['user_id'];
    return LoginResult(
      userId: identity is String && identity.isNotEmpty ? identity : user,
      deviceId: device is String ? device : '',
      token: token,
    );
  }

  /// Одно долгосрочное соединение за новыми сообщениями.
  Future<MatrixReply> sync({String? since}) {
    final query = <String, String>{'timeout': '${_syncWait.inMilliseconds}'};
    if (since != null) query['since'] = since;
    return _get('GET', _url('$_api/sync', query), wait: _syncWait + matrixTimeout);
  }

  /// Отправка сообщения. `txnId` повторного запроса остаётся прежним: узел по
  /// нему узнаёт дубль и не пишет сообщение второй раз.
  Future<String> send(String roomId, String body, String txnId) async {
    final text = body.trim();
    if (text.isEmpty) throw const FormatException('Пустое сообщение');
    final payload = jsonEncode({'msgtype': 'm.text', 'body': text});
    if (utf8.encode(payload).length > maxMatrixBodyBytes) {
      throw const FormatException('Сообщение слишком длинное');
    }
    final path = '$_api/rooms/${Uri.encodeComponent(roomId)}/send/m.room.message/${Uri.encodeComponent(txnId)}';
    final reply = await _get('PUT', _url(path), body: payload);
    final event = reply.json['event_id'];
    return event is String ? event : '';
  }

  /// Снимает эту сессию с узла. Проще отозвать доступ, чем удалять устройство:
  /// `DELETE /devices/{id}` на Tuwunel требует интерактивной авторизации.
  Future<void> logout() async {
    if (_token == null) return;
    await _get('POST', _url('$_api/logout'));
    _token = null;
  }

  /// Кнопки заявки читаются из самой комнаты. Провайдер кладёт свой набор в
  /// state-событие — так сервисные тексты не оказываются зашитыми в клиенте.
  Future<List<QuickReply>> quickReplies(String roomId) async {
    final path = '$_api/rooms/${Uri.encodeComponent(roomId)}/state/$quickRepliesStateType';
    return quickRepliesFromJson((await _get('GET', _url(path))).json);
  }
}

/// Разбирает сообщения комнаты из ответа `/sync`. Возвращает только текстовые
/// сообщения: вложений и звонков в первой версии чата нет.
List<ChatMessage> messagesFromSync(Map<String, dynamic> payload, String roomId, {String? selfUserId}) {
  final join = payload['rooms'];
  if (join is! Map) return const [];
  final rooms = join['join'];
  if (rooms is! Map) return const [];
  final room = rooms[roomId];
  if (room is! Map) return const [];
  final timeline = room['timeline'];
  if (timeline is! Map) return const [];
  final events = timeline['events'];
  if (events is! List) return const [];

  final out = <ChatMessage>[];
  for (final event in events) {
    if (event is! Map) continue;
    if (event['type'] != 'm.room.message') continue;
    final content = event['content'];
    if (content is! Map || content['msgtype'] != 'm.text') continue;
    final body = content['body'];
    if (body is! String) continue;
    final sender = event['sender'] is String ? event['sender'] as String : '';
    if (_isSelf(sender, selfUserId)) continue;
    out.add(ChatMessage(
      sender: sender,
      body: body,
      at: DateTime.fromMillisecondsSinceEpoch(
        event['origin_server_ts'] is int ? event['origin_server_ts'] as int : 0,
        isUtc: true,
      ),
      eventId: event['event_id'] is String ? event['event_id'] as String : '',
    ));
  }
  return out;
}

/// Свои сообщения узел отдаёт в ленте обратно — второй раз их показывать не нужно.
/// Сверка по локальной части: на узлах без федерации она одна на всю учётку.
bool _isSelf(String sender, String? self) {
  if (sender.isEmpty || self == null) return false;
  final mine = mxLocalpart(self);
  return mine.isNotEmpty && mine.toLowerCase() == mxLocalpart(sender).toLowerCase();
}

/// Локальная часть идентификатора: `@имя:узел` → `имя`.
String mxLocalpart(String id) {
  final value = id.startsWith('@') ? id.substring(1) : id;
  final cut = value.indexOf(':');
  return cut < 0 ? value : value.substring(0, cut);
}

/// Тип state-события, в котором провайдер держит кнопки заявки.
const String quickRepliesStateType = 'support.quick_replies';

/// Одна кнопка быстрой заявки: нажатие отправляет `text` обычным сообщением.
class QuickReply {
  const QuickReply({required this.text, this.id = '', this.label});

  final String text;
  final String id;
  final String? label;

  String get caption => (label == null || label!.trim().isEmpty) ? text : label!.trim();
}

/// Разбирает `{"items": [{"id": "c1", "text": "…"}]}`. Пустые и кривые записи
/// отбрасываются: отсутствие кнопок не должно ломать чат.
List<QuickReply> quickRepliesFromJson(Object? json) {
  final items = json is Map ? json['items'] : null;
  if (items is! List) return const [];
  final out = <QuickReply>[];
  for (final item in items) {
    if (item is! Map) continue;
    final text = item['text'];
    if (text is! String || text.trim().isEmpty) continue;
    final label = item['label'];
    out.add(QuickReply(
      text: text.trim(),
      id: item['id'] is String ? item['id'] as String : '',
      label: label is String ? label : null,
    ));
  }
  return out;
}

/// Личные комнаты учётки по `m.direct` из account data. Личная комната поддержки
/// выбирается по ним, а не как «первая в ответе узла».
List<String> directRoomsFromSync(Map<String, dynamic> payload) {
  final data = payload['account_data'];
  final events = data is Map ? data['events'] : null;
  if (events is! List) return const [];
  final out = <String>[];
  for (final event in events) {
    if (event is! Map || event['type'] != 'm.direct') continue;
    final content = event['content'];
    if (content is! Map) continue;
    for (final rooms in content.values) {
      if (rooms is! List) continue;
      for (final room in rooms) {
        if (room is String && room.isNotEmpty && !out.contains(room)) out.add(room);
      }
    }
  }
  return out;
}

/// Сообщение из истории чата.
class ChatMessage {
  const ChatMessage({
    required this.sender,
    required this.body,
    required this.at,
    this.eventId = '',
    this.txnId = '',
    this.pending = false,
    this.failed = false,
  });

  final String sender;
  final String body;
  final DateTime at;
  final String eventId;

  /// Наш идентификатор для исходящих: по нему узнаём, какое сообщение ушло.
  final String txnId;

  /// Мы только поставили сообщение в очередь и ещё не дождались ответа узла.
  final bool pending;
  final bool failed;

  ChatMessage copyWith({bool? pending, bool? failed}) => ChatMessage(
        sender: sender,
        body: body,
        at: at,
        eventId: eventId,
        txnId: txnId,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
      );

  /// Короткое имя отправителя для интерфейса: `@имя:host` → `имя`.
  String get senderName => mxLocalpart(sender);
}

/// Настоящий обмен с узлом: HTTPS со строгой проверкой сертификата.
/// Никаких `badCertificateCallback` и обходов — несовпадение имени это ошибка.
Future<MatrixReply> sendMatrixRequest(MatrixRequest request) async {
  final client = HttpClient()..connectionTimeout = matrixTimeout;
  try {
    final outgoing = await client.openUrl(request.method, request.url).timeout(request.wait);
    if (request.token != null) {
      outgoing.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${request.token}');
    }
    if (request.body != null) {
      outgoing.headers.contentType = ContentType.json;
      outgoing.write(request.body);
    }
    final response = await outgoing.close().timeout(request.wait);

    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxMatrixBytes) {
        throw const FormatException('Ответ узла чата слишком большой');
      }
    }
    if (bytes.isEmpty) return MatrixReply(response.statusCode, const {});
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    return MatrixReply(
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : const {},
    );
  } on FormatException {
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// Текст ошибки для интерфейса: без адреса узла, без токена, без тела ответа.
String chatErrorOf(Object error) {
  if (error is MatrixException) {
    if (error.unknownToken) return 'Доступ к чату закончился';
    if (error.rateLimited) return 'Узел просит отправлять реже';
    if (error.errcode == 'M_LOGIN_REJECTED') return 'Неверный логин или пароль чата';
    if (error.status == 403) return 'Эта комната не доступна учётке';
    if (error.status >= 500) return 'Узел чата временно не отвечает';
    return 'Узел чата ответил ошибкой';
  }
  if (error is FormatException) return error.message;
  if (error is TimeoutException) return 'Узел чата не ответил вовремя';
  if (error is SocketException) return 'Нет связи с узлом чата';
  if (error is HandshakeException) {
    return 'Не удалось установить защищённое соединение с узлом чата';
  }
  return 'Не удалось получить сообщения';
}
