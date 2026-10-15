import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'matrix_api.dart';

/// Сессия чата одной записи провайдера: узел, комната, курсор синхронизации и
/// исходящая очередь. Всё это привязано к провайдеру и удаляется вместе с ним.
class ChatSession {
  const ChatSession({
    required this.providerId,
    required this.homeserver,
    required this.userId,
    required this.roomId,
    this.since,
    this.outbox = const [],
    this.lastError,
  });

  final String providerId;

  /// Полный адрес узла с схемой и портом. Приходит от провайдера или вводится
  /// пользователем — в код клиента такие адреса не вписываются.
  final String homeserver;
  final String userId;
  final String roomId;

  /// Курсор `/sync`: с него восстановление после перезапуска идёт дальше,
  /// а не с начала истории.
  final String? since;
  final List<OutboxItem> outbox;
  final String? lastError;

  bool get isEmpty => roomId.isEmpty;

  ChatSession copyWith({
    String? homeserver,
    String? userId,
    String? roomId,
    String? since,
    List<OutboxItem>? outbox,
    String? lastError,
    bool clearSince = false,
    bool clearError = false,
  }) {
    return ChatSession(
      providerId: providerId,
      homeserver: homeserver ?? this.homeserver,
      userId: userId ?? this.userId,
      roomId: roomId ?? this.roomId,
      since: clearSince ? null : (since ?? this.since),
      outbox: outbox ?? this.outbox,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }

  Map<String, dynamic> toJson() => {
        'homeserver': homeserver,
        'user': userId,
        'room': roomId,
        'since': since,
        'outbox': outbox.map((item) => item.toJson()).toList(),
        'error': lastError,
      };

  /// Битая запись — [FormatException], хранилище пропустит её и оставит прочие.
  static ChatSession fromJson(String providerId, Map<String, dynamic> json) {
    final homeserver = _text(json['homeserver']);
    final room = _text(json['room']);
    if (homeserver == null || room == null) {
      throw const FormatException('В записи чата нет узла или комнаты');
    }
    final raw = json['outbox'];
    return ChatSession(
      providerId: providerId,
      homeserver: homeserver,
      userId: _text(json['user']) ?? '',
      roomId: room,
      since: _text(json['since']),
      outbox: raw is List
          ? raw
              .whereType<Map<String, dynamic>>()
              .map(OutboxItem.fromJson)
              .toList(growable: false)
          : const [],
      lastError: _text(json['error']),
    );
  }
}

/// Сообщение, которое не успело уйти. Повтор отправляется с прежним `txnId`,
/// поэтому узел не пишет дубль.
class OutboxItem {
  const OutboxItem({required this.txnId, required this.body, required this.at});

  final String txnId;
  final String body;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'txn': txnId,
        'body': body,
        'at': at.toIso8601String(),
      };

  static OutboxItem fromJson(Map<String, dynamic> json) {
    final txn = _text(json['txn']);
    final body = _text(json['body']);
    if (txn == null || body == null) throw const FormatException('Очередь повреждена');
    return OutboxItem(txnId: txn, body: body, at: DateTime.tryParse('${json['at']}') ?? DateTime.now());
  }
}

/// Хранилище токена. Реализация — защищённое хранилище ОС (Keystore на Android,
/// Credential Manager на Windows); в испытаниях подменяется памятью.
abstract class TokenVault {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> erase(String key);
}

/// Токен в `SharedPreferences` попасть не может — только сюда.
/// По умолчанию: Keystore (AES-GCM + RSA OAEP) на Android и Credential Manager
/// на Windows.
class SecureTokenVault implements TokenVault {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> erase(String key) async {
    try {
      await _storage.delete(key: key);
    } on Exception {
      // Уже удалено или недоступно: доступ к чату всё равно считается потерянным.
    }
  }
}

/// Память чата: сессии по провайдерам в `chat.v1`, токены отдельно.
class ChatStore {
  ChatStore(this._prefs, this._vault);

  static const String _key = 'chat.v1';
  static const String _tokenPrefix = 'chat.token.v1.';

  final SharedPreferences _prefs;
  final TokenVault _vault;

  static Future<ChatStore> open() async =>
      ChatStore(await SharedPreferences.getInstance(), SecureTokenVault());

  Map<String, Map<String, dynamic>> _readAll() {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is Map<String, dynamic>) '${entry.key}': entry.value as Map<String, dynamic>,
      };
    } on FormatException {
      return {};
    }
  }

  /// Сессия провайдера. Null, если чат ещё не открывали с этой записи.
  ChatSession? sessionOf(String providerId) {
    final raw = _readAll()[providerId];
    if (raw == null) return null;
    try {
      return ChatSession.fromJson(providerId, raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(ChatSession session) async {
    final all = _readAll()..[session.providerId] = session.toJson();
    await _prefs.setString(_key, jsonEncode(all));
  }

  /// Удаляет всё, что принадлежит провайдеру: сессию, курсор, очередь, токен.
  Future<void> drop(String providerId) async {
    final all = _readAll()..remove(providerId);
    await _prefs.setString(_key, jsonEncode(all));
    await _vault.erase(_tokenPrefix + providerId);
  }

  Future<String?> tokenOf(String providerId) => _vault.read(_tokenPrefix + providerId);

  Future<void> saveToken(String providerId, String token) =>
      _vault.write(_tokenPrefix + providerId, token);

  Future<void> eraseToken(String providerId) => _vault.erase(_tokenPrefix + providerId);
}

/// Идентификатор записи сообщения: уникальный для нового и тот же при повторе.
/// Счётчик дописан к времени, чтобы два сообщения, отправленные в одну
/// микросекунду, не получили один `txnId` и не слились на узле.
int _txnSequence = 0;

String newTxnId() => 'c${DateTime.now().microsecondsSinceEpoch}${++_txnSequence}';

/// Проверка адреса узла: только https, с хостом, без пути и без вкраплений.
String? chatHomeserverError(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.isAbsolute || uri.scheme != 'https' || uri.host.isEmpty) {
    return 'Адрес узла чата начинается с https:// и включает порт, например https://узел:8448';
  }
  if (uri.path.isNotEmpty && uri.path != '/') return 'В адресе узла чата не должно быть пути';
  if (uri.userInfo.isNotEmpty) return 'В адресе узла чата не должно быть логина';
  return null;
}

String? _text(Object? value) {
  if (value is! String) return null;
  return value.isEmpty ? null : value;
}

/// Тип для тестовой подмены обмена с узлом.
typedef MatrixCallFactory = MatrixCaller Function(String homeserver);

/// Собирает клиента по сессии.
MatrixClient clientFor(ChatSession session, {String? token, MatrixCaller? call}) =>
    MatrixClient(session.homeserver, token: token, call: call);

/// Сообщения из ответа `/sync` для сессии.
List<ChatMessage> messagesFor(ChatSession session, Map<String, dynamic> payload) =>
    messagesFromSync(payload, session.roomId, selfUserId: session.userId);
