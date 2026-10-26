import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'matrix_api.dart';
import 'services/secure_storage.dart';

/// Chat session of one provider entry: homeserver, room, sync cursor and the
/// outgoing queue. All of it belongs to the provider and is removed with it.
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

  /// Full homeserver address with scheme and port. Comes from the provider or
  /// is entered by the user: such addresses are never written into the code.
  final String homeserver;
  final String userId;
  final String roomId;

  /// The `/sync` cursor: after a restart the sync continues from it rather than
  /// from the start of the history.
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

  /// A broken entry throws [FormatException]; the store skips it and keeps the rest.
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

/// A message that has not been sent yet. A retry goes with the same `txnId`, so
/// the homeserver does not write a duplicate.
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

/// Token storage. The implementation is the OS secure storage (Keystore on
/// Android, Credential Manager on Windows, Keychain on macOS); tests replace it
/// with memory.
abstract class TokenVault {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> erase(String key);
}

/// The token can never go to `SharedPreferences`, only here.
/// Keystore (AES-GCM + RSA OAEP) on Android, Credential Manager on Windows and
/// the login keychain on macOS (see [appSecureStorage]).
class SecureTokenVault implements TokenVault {
  final FlutterSecureStorage _storage = appSecureStorage;

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
      // Already deleted or unavailable: access to the chat is lost either way.
    }
  }
}

/// Chat memory: sessions per provider in `chat.v1`, tokens kept separately.
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

  /// The provider's session. Null if the chat was never opened from this entry.
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

  /// Removes everything that belongs to the provider: session, cursor, queue, token.
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

/// Message transaction id: unique for a new message and the same on a retry.
/// A counter is appended to the time so that two messages sent in the same
/// microsecond do not get one `txnId` and merge on the homeserver.
int _txnSequence = 0;

String newTxnId() => 'c${DateTime.now().microsecondsSinceEpoch}${++_txnSequence}';

/// Homeserver address check: https only, with a host, no path and no extras.
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

/// Type for replacing the homeserver exchange in tests.
typedef MatrixCallFactory = MatrixCaller Function(String homeserver);

/// Builds a client for a session.
MatrixClient clientFor(ChatSession session, {String? token, MatrixCaller? call}) =>
    MatrixClient(session.homeserver, token: token, call: call);

/// Messages from a `/sync` response for a session.
List<ChatMessage> messagesFor(ChatSession session, Map<String, dynamic> payload) =>
    messagesFromSync(payload, session.roomId, selfUserId: session.userId);
