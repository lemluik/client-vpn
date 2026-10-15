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
import 'dart:typed_data';

/// Предел ожидания обычного запроса: и соединение, и чтение.
const Duration matrixTimeout = Duration(seconds: 20);

/// Сколько сервер держит long-poll `/sync`. Одно такое соединение на клиента.
const Duration matrixSyncWait = Duration(seconds: 25);

/// Предел тела ответа узла: история страницы сообщений заметно меньше.
const int maxMatrixBytes = 2 * 1024 * 1024;

/// Предел нашего тела: на узле nginx ограничивает запрос 1 MiB.
const int maxMatrixBodyBytes = 1024 * 1024;

/// Предел вложения в обе стороны: снимок экрана весит единицы мегабайт, а
/// держать в памяти клиенту больше — уже расточительно.
const int maxMatrixMediaBytes = 8 * 1024 * 1024;

const String _api = '/_matrix/client/v3';

/// Классический медиа-API. Часть узлов отдаёт вложения только через него.
const String _mediaApi = '/_matrix/media/v3';

/// Медиа-API с авторизацией (Matrix 1.11+): файл не отдадут без токена.
const String _mediaAuthApi = '/_matrix/client/v1/media';

/// Ответ узла: код, разобранный JSON и байты, если это файл.
class MatrixReply {
  const MatrixReply(this.status, this.json, {this.bytes});

  final int status;
  final Map<String, dynamic> json;

  /// Содержимое вложения. Заполнено только у запросов с `binary`.
  final Uint8List? bytes;

  bool get ok => status >= 200 && status < 300;

  String get errcode => json['errcode'] is String ? json['errcode'] as String : '';

  bool get unknownToken => status == 401 || errcode == 'M_UNKNOWN_TOKEN';
}

/// Запрос к узлу. `wait` отдельно от URL, чтобы long-poll ждал дольше обычного.
/// Тело — либо строка JSON (`body`), либо байты вложения (`bytes`).
class MatrixRequest {
  const MatrixRequest(
    this.method,
    this.url, {
    this.body,
    this.bytes,
    this.contentType,
    this.token,
    this.wait = matrixTimeout,
    this.binary = false,
  });

  final String method;
  final Uri url;
  final String? body;
  final Uint8List? bytes;
  final String? contentType;
  final String? token;
  final Duration wait;

  /// Ответ — файл, а не JSON: его не разбирают и не ограничивают как текст.
  final bool binary;
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

  Future<MatrixReply> _get(
    String method,
    Uri url, {
    String? body,
    Uint8List? bytes,
    String? contentType,
    Duration? wait,
    bool binary = false,
  }) async {
    final reply = await _call(MatrixRequest(
      method,
      url,
      body: body,
      bytes: bytes,
      contentType: contentType,
      token: _token,
      wait: wait ?? matrixTimeout,
      binary: binary,
    ));
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
    return _sendEvent(roomId, txnId, {'msgtype': 'm.text', 'body': text});
  }

  /// Отправка снимка: файл уже загружен на узел, в комнату уходит ссылка `mxc`.
  /// Подпись — имя файла, его дежурный видит и в своей программе.
  Future<String> sendImage(
    String roomId,
    String txnId, {
    required String filename,
    required String mxc,
    String? mimeType,
    int size = 0,
    int width = 0,
    int height = 0,
  }) {
    final info = <String, dynamic>{
      if (mimeType != null && mimeType.isNotEmpty) 'mimetype': mimeType,
      if (size > 0) 'size': size,
      if (width > 0) 'w': width,
      if (height > 0) 'h': height,
    };
    return _sendEvent(roomId, txnId, {
      'msgtype': 'm.image',
      'body': filename,
      'filename': filename,
      'url': mxc,
      if (info.isNotEmpty) 'info': info,
    });
  }

  Future<String> _sendEvent(String roomId, String txnId, Map<String, dynamic> content) async {
    final payload = jsonEncode(content);
    if (utf8.encode(payload).length > maxMatrixBodyBytes) {
      throw const FormatException('Сообщение слишком длинное');
    }
    final path = '$_api/rooms/${Uri.encodeComponent(roomId)}/send/m.room.message/${Uri.encodeComponent(txnId)}';
    final reply = await _get('PUT', _url(path), body: payload);
    final event = reply.json['event_id'];
    return event is String ? event : '';
  }

  /// Загрузка вложения на узел, возвращает `mxc://…`. Узлы настроены по-разному:
  /// где-то медиа-API закрыт снаружи, где-то нет авторизованного варианта,
  /// поэтому при 404/405 пробуем второй путь.
  Future<String> upload(
    Uint8List bytes, {
    required String filename,
    String mimeType = 'application/octet-stream',
  }) async {
    if (bytes.isEmpty) throw const FormatException('В файле нет данных');
    if (bytes.length > maxMatrixMediaBytes) {
      throw const FormatException('Файл больше 8 МБ: уменьшите снимок');
    }
    final query = {'filename': filename};
    MatrixReply reply;
    try {
      reply = await _get(
        'POST',
        _url('$_mediaAuthApi/upload', query),
        bytes: bytes,
        contentType: mimeType,
      );
    } on MatrixException catch (error) {
      if (error.status != 404 && error.status != 405) rethrow;
      reply = await _get(
        'POST',
        _url('$_mediaApi/upload', query),
        bytes: bytes,
        contentType: mimeType,
      );
    }
    final uri = reply.json['content_uri'];
    if (uri is! String || splitMxc(uri) == null) {
      throw const MatrixException(502, 'M_MISSING_CONTENT_URI');
    }
    return uri;
  }

  /// Байты вложения по ссылке `mxc://узел/ид`.
  Future<Uint8List> download(String mxc) async {
    final parts = splitMxc(mxc);
    if (parts == null) throw const FormatException('Ссылка на вложение повреждена');
    final tail = '${Uri.encodeComponent(parts.$1)}/${Uri.encodeComponent(parts.$2)}';
    MatrixReply reply;
    try {
      reply = await _get('GET', _url('$_mediaAuthApi/download/$tail'), binary: true);
    } on MatrixException catch (error) {
      if (error.status != 404 && error.status != 405) rethrow;
      reply = await _get('GET', _url('$_mediaApi/download/$tail'), binary: true);
    }
    final bytes = reply.bytes;
    if (bytes == null || bytes.isEmpty) throw const MatrixException(502, 'M_EMPTY_MEDIA');
    return bytes;
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

  /// Лента комнаты назад: после перезапуска локальная лента пуста, а токен
  /// синхронизации уже прошёл старые события, поэтому их надо запросить явно.
  Future<List<ChatMessage>> history(String roomId, {int limit = 50}) async {
    final path = '$_api/rooms/${Uri.encodeComponent(roomId)}/messages';
    final reply = await _get('GET', _url(path, {'dir': 'b', 'limit': '$limit'}));
    final chunk = reply.json['chunk'];
    return chunk is List ? messagesFromChunk(chunk) : const <ChatMessage>[];
  }
}

/// Разбирает сообщения комнаты из ответа `/sync`. Берёт текст и изображения:
/// остальные типы (звонки, файлы произвольного вида) чат поддержки не показывает.
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
    final message = chatMessageFromEvent(event, selfUserId: selfUserId);
    if (message != null) out.add(message);
  }
  return out;
}

/// Одно событие ленты в сообщение чата; `null` — событие не из ленты.
/// В живом sync наши исходящие не дублируются (их рисует локальная очередь),
/// а в подтяжке истории они нужны — отсюда `includeSelf`.
ChatMessage? chatMessageFromEvent(Map<Object?, Object?> event,
    {String? selfUserId, bool includeSelf = false}) {
  if (event['type'] != 'm.room.message') return null;
  final content = event['content'];
  if (content is! Map) return null;
  final body = content['body'] is String ? content['body'] as String : '';

  ChatImage? image;
  if (content['msgtype'] == 'm.image') {
    image = imageFromContent(content);
    if (image == null) return null;
  } else if (content['msgtype'] != 'm.text' || body.trim().isEmpty) {
    return null;
  }

  final sender = event['sender'] is String ? event['sender'] as String : '';
  if (!includeSelf && _isSelf(sender, selfUserId)) return null;
  final unsigned = event['unsigned'];
  return ChatMessage(
    sender: sender,
    body: image == null ? body : image.name,
    at: DateTime.fromMillisecondsSinceEpoch(
      event['origin_server_ts'] is int ? event['origin_server_ts'] as int : 0,
      isUtc: true,
    ),
    eventId: event['event_id'] is String ? event['event_id'] as String : '',
    txnId: unsigned is Map && unsigned['transaction_id'] is String
        ? unsigned['transaction_id'] as String
        : '',
    image: image,
  );
}

/// Лента `/messages` приходит в обратном порядке: разворачиваем в хронологию.
List<ChatMessage> messagesFromChunk(List<Object?> chunk) {
  final out = <ChatMessage>[];
  for (final event in chunk) {
    if (event is! Map) continue;
    final message = chatMessageFromEvent(event, includeSelf: true);
    if (message != null) out.add(message);
  }
  return out.reversed.toList();
}

/// Содержимое `m.image` → описание снимка. Без годной ссылки `mxc://` файл
/// нечем показать, поэтому такое сообщение просто не попадает в ленту.
ChatImage? imageFromContent(Map<dynamic, dynamic> content) {
  final url = content['url'];
  if (url is! String || splitMxc(url) == null) return null;
  final info = content['info'];
  final meta = info is Map ? info : const {};
  final body = content['body'];
  return ChatImage(
    mxc: url,
    name: body is String && body.trim().isNotEmpty ? body.trim() : 'Изображение',
    mimeType: meta['mimetype'] is String ? meta['mimetype'] as String : null,
    size: meta['size'] is int ? meta['size'] as int : 0,
    width: meta['w'] is int ? meta['w'] as int : 0,
    height: meta['h'] is int ? meta['h'] as int : 0,
  );
}

/// `mxc://узел/ид` → (`узел`, `ид`). Всё остальное ссылкой на вложение не считается.
(String, String)? splitMxc(String value) {
  if (!value.startsWith('mxc://')) return null;
  final rest = value.substring('mxc://'.length);
  final cut = rest.indexOf('/');
  if (cut <= 0 || cut == rest.length - 1) return null;
  return (rest.substring(0, cut), rest.substring(cut + 1));
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

/// Снимок в чате: ссылка на узле, подпись и байты для превью. У своего файла
/// байты есть сразу, у чужого появляются после скачивания.
class ChatImage {
  const ChatImage({
    required this.mxc,
    required this.name,
    this.mimeType,
    this.size = 0,
    this.width = 0,
    this.height = 0,
    this.bytes,
  });

  /// Пусто, пока файл не загружен на узел.
  final String mxc;
  final String name;
  final String? mimeType;
  final int size;
  final int width;
  final int height;
  final Uint8List? bytes;

  bool get loaded => bytes != null && bytes!.isNotEmpty;

  ChatImage copyWith({String? mxc, Uint8List? bytes}) => ChatImage(
        mxc: mxc ?? this.mxc,
        name: name,
        mimeType: mimeType,
        size: size,
        width: width,
        height: height,
        bytes: bytes ?? this.bytes,
      );
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
    this.image,
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

  /// Снимок вместо текста. `body` у такого сообщения — имя файла.
  final ChatImage? image;

  ChatMessage copyWith({bool? pending, bool? failed, ChatImage? image}) => ChatMessage(
        sender: sender,
        body: body,
        at: at,
        eventId: eventId,
        txnId: txnId,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
        image: image ?? this.image,
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
    final attachment = request.bytes;
    if (attachment != null) {
      outgoing.headers.contentType =
          ContentType.parse(request.contentType ?? 'application/octet-stream');
      outgoing.headers.contentLength = attachment.length;
      outgoing.add(attachment);
    } else if (request.body != null) {
      outgoing.headers.contentType = ContentType.json;
      outgoing.write(request.body);
    }
    final response = await outgoing.close().timeout(request.wait);

    final limit = request.binary ? maxMatrixMediaBytes : maxMatrixBytes;
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > limit) {
        throw FormatException(
          request.binary ? 'Вложение больше 8 МБ' : 'Ответ узла чата слишком большой',
        );
      }
    }
    if (request.binary) {
      return MatrixReply(response.statusCode, const {}, bytes: Uint8List.fromList(bytes));
    }
    if (bytes.isEmpty) return MatrixReply(response.statusCode, const {});
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return MatrixReply(
        response.statusCode,
        decoded is Map<String, dynamic> ? decoded : const {},
      );
    } on FormatException {
      // Не JSON: например, страница прокси вместо ответа узла. Код важнее тела.
      return MatrixReply(response.statusCode, const {});
    }
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
    if (error.status == 413) return 'Узел не принял такой большой файл';
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
