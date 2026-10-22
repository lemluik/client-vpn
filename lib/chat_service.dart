import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_store.dart';
import 'matrix_api.dart';
import 'provider.dart';

/// Состояние чата для интерфейса. `blocked` — токен отозван или доступ кончился:
/// сам клиент его не восстановит, выдаёт провайдер.
enum ChatStatus { signedOut, connecting, live, retrying, blocked }

/// Задержка между попытками. В испытаниях подменяется мгновенной, чтобы
/// проверять backoff без реального ожидания.
typedef ChatDelay = Future<void> Function(Duration delay);

/// Ретраи идут по 1/2/4/8/16 с, дальше очередь ждёт сети.
const List<Duration> chatBackoffs = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
];

/// Прислала ли подписка всё нужное для автологина. Экран проверяет это до
/// входа: `null` от [ChatService.signInWithProvider] означает и удачу, и
/// «входить нечем», а отличить второе от сетевого сбоя надо заранее.
bool chatCredentialsReady(Provider? provider) =>
    provider != null &&
    provider.chatHomeserver != null &&
    provider.chatUser != null &&
    provider.chatPassword != null;

/// Двигатель чата: один long-poll `/sync`, очередь с `txnId`, курсор на диске.
///
/// Всё, что видно пользователю, переживает перезапуск: `since` и очередь
/// сохраняются в [ChatStore] на каждое изменение.
class ChatService extends ChangeNotifier {
  ChatService(this._store, {MatrixCaller? call, ChatDelay? delay, DateTime Function()? now})
      : _call = call,
        _delay = delay ?? _realDelay,
        _now = now ?? DateTime.now;

  static Future<void> _realDelay(Duration delay) => Future<void>.delayed(delay);

  final ChatStore _store;
  final MatrixCaller? _call;
  final ChatDelay _delay;
  final DateTime Function() _now;

  ChatSession? _session;
  MatrixClient? _client;
  final List<ChatMessage> _messages = [];
  List<QuickReply> _quickReplies = const [];
  ChatStatus _status = ChatStatus.signedOut;
  String? _error;
  int _attempts = 0;
  bool _running = false;

  /// Счётчик поколений цикла приёма: `stop()` его увеличивает, и старый цикл,
  /// досчитав долгий `sync`, выходит сам вместо того чтобы работать наравне
  /// с новым.
  int _generation = 0;

  /// Служба уничтожена вместе с состоянием приложения: экран чата закрывается
  /// позже, и его `stop()` не должен звать слушателей снятого оповестителя.
  bool _disposed = false;

  /// Вложения, которые сейчас качаются: один запрос на файл, иначе лента
  /// заведёт по копии запроса на каждое сообщение с тем же снимком.
  final Set<String> _downloading = {};

  ChatStatus get status => _status;

  String? get error => _error;

  ChatSession? get session => _session;

  bool get signedIn => _session != null && _client != null && _client!.signedIn;

  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Кнопки заявки, которые лежат в комнате. Пусто — значит провайдер их не кладёт.
  List<QuickReply> get quickReplies => List.unmodifiable(_quickReplies);

  int get queued => _session?.outbox.length ?? 0;

  /// Поднимает сохранённую сессию провайдера и начинает приём.
  /// Если сессии нет, но есть credentials в провайдере — пробует авто-логин.
  Future<bool> resume(String providerId, {Provider? provider}) async {
    final session = _store.sessionOf(providerId);
    if (session == null) {
      // Нет сохранённой сессии: пробуем авто-логин если есть credentials
      if (chatCredentialsReady(provider)) {
        final error = await signInWithProvider(provider!);
        return error == null;
      }
      _status = ChatStatus.signedOut;
      notifyListeners();
      return false;
    }
    final token = await _store.tokenOf(providerId);
    if (token == null || token.isEmpty) {
      // Токен утерян (переустановка): пробуем авто-логин
      if (chatCredentialsReady(provider)) {
        final error = await signInWithProvider(provider!);
        return error == null;
      }
      _session = session;
      _hydrate(session);
      await fail('Доступ к чату закончился', ChatStatus.blocked);
      return false;
    }
    _session = session;
    _hydrate(session);
    _client = MatrixClient(session.homeserver, token: token, call: _call);
    _status = ChatStatus.connecting;
    _error = null;
    notifyListeners();
    await _reconcileRoom();
    _start();
    unawaited(_backfill());
    unawaited(_loadReplies());
    return true;
  }

  /// Комната из сохранённой сессии могла устареть: личную комнату пересоздают,
  /// учётку переносят. Один раз за вход сверяем с фактом узла и предпочитаем
  /// личную (m.direct) комнату общей.
  Future<void> _reconcileRoom() async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) return;
    try {
      final reply = await client.sync();
      final join = (reply.json['rooms'] as Map?)?['join'];
      if (join is! Map || join.isEmpty) return;
      final joined = join.keys.whereType<String>().toList();
      final direct = directRoomsFromSync(reply.json).where(joined.contains).toList();
      final current = session.roomId;
      if (joined.contains(current) && (direct.isEmpty || direct.contains(current))) {
        return;
      }
      // Токен синхронизации общий для всех комнат: он уже мог пройти события
      // новой комнаты, пока клиент сидел в старой. Сбрасываем — полный sync
      // вернёт недавнюю ленту новой комнаты.
      _session = session.copyWith(
        roomId: direct.isNotEmpty ? direct.first : joined.first,
        clearSince: true,
      );
      _messages.clear();
      _downloading.clear();
      await _persist();
    } on Object {
      // Узел не ответил: остаёмся на сохранённой комнате, цикл повторит приём.
    }
  }

  /// История комнаты после перезапуска: локальная лента пуста, а токен sync
  /// уже прошёл старые события, поэтому последние запрашиваем явно. Свои
  /// сообщения, которые локальная очередь ещё рисует сама, не дублируем.
  Future<void> _backfill() async {
    final client = _client;
    final session = _session;
    if (client == null || session == null) return;
    try {
      final past = await client.history(session.roomId);
      if (past.isEmpty) return;
      final knownEvents =
          _messages.where((m) => m.eventId.isNotEmpty).map((m) => m.eventId).toSet();
      final knownTxn =
          _messages.where((m) => m.txnId.isNotEmpty).map((m) => m.txnId).toSet();
      final fresh = past
          .where((m) =>
              (m.eventId.isEmpty || !knownEvents.contains(m.eventId)) &&
              (m.txnId.isEmpty || !knownTxn.contains(m.txnId)))
          .toList();
      if (fresh.isEmpty) return;
      _messages.insertAll(0, fresh);
      _messages.sort((a, b) => a.at.compareTo(b.at));
      _loadPendingImages();
      notifyListeners();
    } on Object {
      // История не подтянулась: приём новых сообщений идёт как обычно.
    }
  }

  /// Вход готовой учёткой. Пароль в историю и в журнал не попадает, токен
  /// уходит в защищённое хранилище ОС.
  Future<String?> signIn({
    required String providerId,
    required String homeserver,
    required String user,
    required String password,
    String? roomId,
  }) async {
    final bad = chatHomeserverError(homeserver);
    if (bad != null) return bad;
    if (user.trim().isEmpty || password.isEmpty) return 'Введите логин и пароль чата';

    _status = ChatStatus.connecting;
    _error = null;
    notifyListeners();

    final client = MatrixClient(_normalise(homeserver), call: _call);
    try {
      await client.versions();
      final login = await client.login(user.trim(), password);
      var room = roomId?.trim();
      if (room == null || room.isEmpty) {
        room = await _firstRoom(client);
      } else {
        // Комнату из подписки создаёт служебная учётка узла, и свежий клиент в
        // ней только приглашённый: без принятого приглашения лента и история
        // вернут пустоту или 403.
        await _ensureMembership(client, room);
      }
      if (room == null || room.isEmpty) {
        return 'У этой учётки нет комнаты: чат ещё не выпущен';
      }

      _client = client;
      // Новый вход — новая пара «узел + комната»: старая сессия и её токен
      // не переносятся между узлами.
      await _store.drop(providerId);
      _session = ChatSession(
        providerId: providerId,
        homeserver: client.homeserver,
        userId: login.userId,
        roomId: room,
      );
      await _store.saveToken(providerId, login.token);
      await _persist();
      _messages.clear();
      _downloading.clear();
      _status = ChatStatus.live;
      notifyListeners();
      _start();
      unawaited(_loadReplies());
      return null;
    } on Object catch (error) {
      return fail(chatErrorOf(error), error is MatrixException && error.unknownToken
          ? ChatStatus.blocked
          : ChatStatus.retrying);
    }
  }

  /// Авто-логин по учётным данным из провайдера. Если credentials есть —
  /// вход происходит без участия пользователя (МЧ-5.1).
  ///
  /// `null` означает и удачный вход, и «входить нечем»: отличать одно от
  /// другого вызывающий код обязан сам, через [chatCredentialsReady] и
  /// [signedIn]. Сетевой сбой всегда возвращается текстом ошибки.
  Future<String?> signInWithProvider(Provider provider) async {
    final user = provider.chatUser;
    final password = provider.chatPassword;
    final homeserver = provider.chatHomeserver;
    if (user == null || password == null || homeserver == null) {
      return null; // Нет credentials — авто-логин невозможен
    }
    return signIn(
      providerId: provider.id,
      homeserver: homeserver,
      user: user,
      password: password,
      roomId: provider.chatRoomId,
    );
  }

  /// Членство в комнате, которую прислала подписка: узел добавляет учётку
  /// приглашением, поэтому до чтения ленты приглашение надо принять. Второй
  /// `/sync` нужен, чтобы комната появилась в `rooms.join` до сохранения
  /// сессии — иначе курсор запишется на состояние без нашей комнаты.
  Future<void> _ensureMembership(MatrixClient client, String roomId) async {
    final reply = await client.sync();
    final join = (reply.json['rooms'] as Map?)?['join'];
    if (join is Map && join.containsKey(roomId)) return;
    await client.joinRoom(roomId);
    await client.sync();
  }

  /// Отправка: сразу в очередь и в историю со статусом «в очереди», потом на узел.
  Future<String?> send(String text) async {
    final session = _session;
    if (session == null) return 'Чат не открыт';
    final body = text.trim();
    if (body.isEmpty) return null;

    final item = OutboxItem(txnId: newTxnId(), body: body, at: _now());
    final queued = [...session.outbox, item];
    _session = session.copyWith(outbox: queued);
    _messages.add(ChatMessage(
      sender: session.userId,
      body: body,
      at: item.at,
      txnId: item.txnId,
      pending: true,
    ));
    await _persist();
    notifyListeners();
    await _flush();
    return _error;
  }

  /// Отправка снимка: файл уходит на узел, а в комнату — сообщение `m.image`.
  /// В очередь на диске вложение не кладём: мегабайты в настройках не хранят,
  /// поэтому при сбое снимок помечается неотправленным и выбирается заново.
  Future<String?> sendImage({
    required Uint8List bytes,
    required String name,
    String? mimeType,
    int width = 0,
    int height = 0,
  }) async {
    final session = _session;
    final client = _client;
    if (session == null || client == null) return 'Чат не открыт';
    if (bytes.isEmpty) return 'В файле нет данных';
    if (bytes.length > maxMatrixMediaBytes) return 'Файл больше 8 МБ: уменьшите снимок';
    if (_status == ChatStatus.blocked) return _error ?? 'Доступ к чату закончился';

    final label = name.trim().isEmpty ? 'Изображение' : name.trim();
    final item = OutboxItem(txnId: newTxnId(), body: label, at: _now());
    _messages.add(ChatMessage(
      sender: session.userId,
      body: label,
      at: item.at,
      txnId: item.txnId,
      pending: true,
      image: ChatImage(
        mxc: '',
        name: label,
        mimeType: mimeType,
        size: bytes.length,
        width: width,
        height: height,
        bytes: bytes,
      ),
    ));
    notifyListeners();

    try {
      final mxc = await client.upload(
        bytes,
        filename: label,
        mimeType: mimeType ?? 'application/octet-stream',
      );
      await client.sendImage(
        session.roomId,
        item.txnId,
        filename: label,
        mxc: mxc,
        mimeType: mimeType,
        size: bytes.length,
        width: width,
        height: height,
      );
      _markSent(item.txnId);
      _error = null;
      if (_status == ChatStatus.retrying) _status = ChatStatus.connecting;
      notifyListeners();
    } on Object catch (error) {
      if (error is MatrixException && error.unknownToken) {
        return fail('Доступ к чату закончился', ChatStatus.blocked);
      }
      _markFailed(item.txnId, chatErrorOf(error));
    }
    return _error;
  }

  /// Пробует снова после «нет связи»: очередь и курсор на месте.
  Future<void> retry() async {
    _attempts = 0;
    if (_status == ChatStatus.retrying) _status = ChatStatus.connecting;
    notifyListeners();
    if (_session != null && _client != null && !_running) _start();
    await _flush();
  }

  /// Останавливает приём, когда экран чата закрыт: на узле лимит соединений,
  /// и держать long-poll без пользователя в интерфейсе нельзя. Текущий запрос
  /// доживёт до ответа узла (до 25 с), новых не заводим.
  void stop() {
    if (_disposed) return;
    _running = false;
    _generation++;
    notifyListeners();
  }

  /// Экран чата закрывают — приём останавливается, но сессия и токен живут.
  /// При повторном открытии цикл поднимаем заново: иначе лента стоит, хотя
  /// вход выполнен и новых сообщений клиент не видит.
  void resumePolling() {
    if (_running || _session == null || _client == null) return;
    if (_status == ChatStatus.blocked) return;
    _status = ChatStatus.connecting;
    _error = null;
    _attempts = 0;
    notifyListeners();
    _start();
    unawaited(_backfill());
  }

  /// Забывает чат провайдера вместе с его записью: сессия, курсор, очередь и
  /// токен не должны пережить удаление подписки.
  Future<void> forget(String providerId) async {
    final session = _session;
    if (session != null && session.providerId == providerId) {
      await signOut();
      return;
    }
    await _store.drop(providerId);
  }

  /// Выход: сессия снимается с узла, токен стирается, история и курсор удаляются.
  Future<void> signOut() async {
    final session = _session;
    _running = false;
    if (_client != null && session != null) {
      try {
        await _client!.logout();
      } on Object {
        // Узел мог уже отозвать токен: локально всё равно всё стираем.
      }
    }
    _messages.clear();
    _quickReplies = const [];
    _downloading.clear();
    _client = null;
    _session = null;
    _status = ChatStatus.signedOut;
    _error = null;
    if (session != null) await _store.drop(session.providerId);
    notifyListeners();
  }

  /// Текст ошибки относится к прошлой попытке: на чистой форме входа он только
  /// путает — пользователь ещё ничего не ввёл.
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  Future<String?> fail(String text, ChatStatus state) async {
    _error = text;
    _status = state;
    final session = _session;
    if (session != null) _session = session.copyWith(lastError: text);
    notifyListeners();
    return text;
  }

  void _start() {
    if (_running) return;
    _running = true;
    final generation = ++_generation;
    unawaited(_loop(generation));
  }

  /// Последовательный цикл: отправка очереди, затем одно долгосрочное
  /// соединение. Параллельных `sync` не заводим — на узле лимит соединений.
  /// [generation] отличает этот цикл от прежнего, остановленного `stop()`:
  /// долгий `sync` прервать нельзя, он досчитывает свой век и выходит сам,
  /// а новый цикл тем временем уже поднят повторным открытием экрана.
  Future<void> _loop(int generation) async {
    while (_running &&
        generation == _generation &&
        _session != null &&
        _client != null) {
      await _flush();
      if (!_running || generation != _generation) break;
      final session = _session!;
      try {
        final reply = await _client!.sync(since: session.since);
        if (generation != _generation) break;
        _attempts = 0;
        _absorb(reply.json);
        _status = ChatStatus.live;
        _error = null;
        notifyListeners();
      } on Object catch (error) {
        if (generation != _generation) break;
        if (error is MatrixException && error.unknownToken) {
          await fail('Доступ к чату закончился', ChatStatus.blocked);
          _running = false;
          break;
        }
        _attempts++;
        if (_attempts > chatBackoffs.length) {
          await fail('${chatErrorOf(error)} — очередь ждёт сети', ChatStatus.retrying);
          _running = false;
          break;
        }
        _status = ChatStatus.retrying;
        _error = chatErrorOf(error);
        notifyListeners();
        await _delay(chatBackoffs[_attempts - 1]);
      }
    }
  }

  /// Отправляет очередь по одной. Повтор идёт с прежним `txnId` — узел
  /// дедуплицирует, так что ретрай не плодит дублей.
  Future<void> _flush() async {
    final existing = _session;
    final client = _client;
    if (existing == null || client == null || existing.outbox.isEmpty) return;
    var session = existing;

    for (final item in List.of(session.outbox)) {
      try {
        await client.send(session.roomId, item.body, item.txnId);
        session = session.copyWith(
          outbox: session.outbox.where((left) => left.txnId != item.txnId).toList(),
        );
        _markSent(item.txnId);
        _session = session;
        await _persist();
        notifyListeners();
      } on Object catch (error) {
        if (error is MatrixException && error.unknownToken) {
          await fail('Доступ к чату закончился', ChatStatus.blocked);
          return;
        }
        if (error is MatrixException && error.rateLimited) {
          await _delay(chatBackoffs[0]);
        }
        _markFailed(item.txnId, chatErrorOf(error));
        return;
      }
    }
  }

  void _absorb(Map<String, dynamic> payload) {
    final session = _session;
    if (session == null) return;
    final next = payload['next_batch'];
    if (next is String && next.isNotEmpty) {
      _session = session.copyWith(since: next);
      unawaited(_persist());
    }
    var arrived = 0;
    for (final message in messagesFor(session, payload)) {
      if (_messages.any((old) => old.eventId.isNotEmpty && old.eventId == message.eventId)) {
        continue;
      }
      _messages.add(message);
      arrived++;
    }
    _loadPendingImages();
    // Оператор меняет кнопки по ходу диалога, поэтому после входящих перечитываем
    // state-событие: набор кнопок обязан отражать текущее состояние заявки.
    if (arrived > 0 || _hasRepliesUpdate(payload, session.roomId)) {
      unawaited(_loadReplies());
    }
  }

  /// Чужой снимок приходит ссылкой: байты докачиваются отдельно, по одному
  /// запросу на ссылку. Лента перерисовывается, когда файл получен.
  void _loadPendingImages() {
    final client = _client;
    if (client == null) return;
    for (final message in List.of(_messages)) {
      final image = message.image;
      if (image == null || image.loaded || image.mxc.isEmpty) continue;
      if (!_downloading.add(image.mxc)) continue;
      unawaited(_downloadImage(client, image.mxc));
    }
  }

  Future<void> _downloadImage(MatrixClient client, String mxc) async {
    try {
      final bytes = await client.download(mxc);
      for (var i = 0; i < _messages.length; i++) {
        final image = _messages[i].image;
        if (image != null && image.mxc == mxc && !image.loaded) {
          _messages[i] = _messages[i].copyWith(image: image.copyWith(bytes: bytes));
        }
      }
      notifyListeners();
    } on Object {
      // Файл не скачался — в ленте остаётся подпись, приём сообщений продолжается.
    } finally {
      _downloading.remove(mxc);
    }
  }

  /// Мост vpn-mx-bridge может обновить кнопки без нового сообщения — тогда
  /// state-событие support.quick_replies приходит само по себе. В инкрементальном
  /// /sync оно лежит в timeline нашей комнаты, при первичном — в разделе state.
  bool _hasRepliesUpdate(Map<String, dynamic> payload, String roomId) {
    final rooms = payload['rooms'];
    if (rooms is! Map) return false;
    final join = rooms['join'];
    if (join is! Map) return false;
    final room = join[roomId];
    if (room is! Map) return false;

    for (final key in const ['timeline', 'state']) {
      final section = room[key];
      if (section is! Map) continue;
      final events = section['events'];
      if (events is! List) continue;
      for (final event in events) {
        if (event is Map && event['type'] == quickRepliesStateType) return true;
      }
    }

    return false;
  }

  /// Кнопки заявки — факультативные: у провайдера их может не быть, а ответ узла
  /// может не успеть прийти. Ни один из вариантов не роняет чат.
  Future<void> _loadReplies() async {
    final client = _client;
    final room = _session?.roomId;
    if (client == null || room == null || !client.signedIn) return;
    try {
      final found = await client.quickReplies(room);
      if (found.isEmpty || _session?.roomId != room) return;
      _quickReplies = found;
      notifyListeners();
    } on Object {
      // Нет события — нет кнопок; текст в поле ввода никуда не девается.
    }
  }

  Future<String?> _firstRoom(MatrixClient client) async {
    final reply = await client.sync();
    final join = reply.json['rooms'];
    if (join is! Map) return null;
    final rooms = join['join'];
    if (rooms is! Map || rooms.isEmpty) return null;
    for (final direct in directRoomsFromSync(reply.json)) {
      if (rooms.containsKey(direct)) return direct;
    }
    return '${rooms.keys.first}';
  }

  /// Возвращает в ленту то, что не успело уйти: очередь переживает перезапуск.
  void _hydrate(ChatSession session) {
    _messages
      ..clear()
      ..addAll(session.outbox.map((item) => ChatMessage(
            sender: session.userId,
            body: item.body,
            at: item.at,
            txnId: item.txnId,
            pending: true,
          )));
  }

  void _markSent(String txnId) {
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].pending && _messages[i].txnId == txnId) {
        _messages[i] = _messages[i].copyWith(pending: false);
      }
    }
  }

  void _markFailed(String txnId, String reason) {
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].pending && _messages[i].txnId == txnId) {
        _messages[i] = _messages[i].copyWith(failed: true);
      }
    }
    _error = reason;
    notifyListeners();
  }

  Future<void> _persist() async {
    final session = _session;
    if (session != null) await _store.save(session);
  }

  /// Порт и схему оставляем как есть, убираем только хвостовой слэш.
  String _normalise(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    // Цикл приёма проверяет поколение после долгого `sync`: без этого он
    // оповестит слушателей уже снятого оповестителя.
    _generation++;
    super.dispose();
  }
}
