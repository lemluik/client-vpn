import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'chat_service.dart';
import 'matrix_api.dart';
import 'provider.dart';

/// Снимок, который выбрал пользователь: имя и содержимое.
class PickedImage {
  const PickedImage({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Выбор снимка. В испытаниях подменяется: системный диалог в тесте не открыть.
typedef ImagePicker = Future<PickedImage?> Function();

/// Диалог выбора изображения: на телефоне это галерея, на компьютере — проводник.
/// Содержимое читаем через picker: на мобильной платформе путь это content URI,
/// которым файл напрямую не открыть.
Future<PickedImage?> pickSupportImage() async {
  final picked = await FilePicker.pickFile(
    dialogTitle: 'Выберите снимок',
    type: FileType.image,
  );
  if (picked == null) return null;
  return PickedImage(name: picked.name, bytes: await picked.readAsBytes());
}

/// Тип файла по расширению: узел кладёт его в `info.mimetype`, и дежурный видит
/// снимок тем, чем он сделан.
String imageMimeType(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    _ => 'application/octet-stream',
  };
}

/// Чат поддержки внутри клиента: узел и комнату даёт провайдер, учётка уже
/// выпущена. Самостоятельной регистрации на узлах нет, звонков тоже — только
/// текст и снимки экрана.
///
/// Провайдер необязателен: без него чат доступен как «первая помощь» тому, у
/// кого ключ ещё не добавлен или туннель не поднимается. Такая сессия
/// хранится под отдельным ключом и с данными провайдера не смешивается.
class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({
    required this.state,
    this.provider,
    this.pickImage,
    super.key,
  });

  final AppState state;
  final Provider? provider;

  /// Чем выбирать снимок. По умолчанию — системный диалог.
  final ImagePicker? pickImage;

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  static const _directScope = 'direct';

  final TextEditingController _draft = TextEditingController();
  final ScrollController _scroll = ScrollController();

  ChatService? get _chat => widget.state.chat;
  String get _scopeId => widget.provider?.id ?? _directScope;

  @override
  void initState() {
    super.initState();
    _chat?.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _chat?.removeListener(_onChange);
    // Экран закрыт — приём останавливаем: на узле лимит соединений.
    _chat?.stop();
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _open() async {
    final chat = _chat;
    if (chat == null) return;
    if (chat.session == null) {
      chat.clearError();
      await chat.resume(_scopeId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Поддержка')),
        body: const Center(child: Text('Чат недоступен в этой сборке')),
      );
    }

    final session = chat.session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Поддержка'),
        actions: [
          if (session != null)
            IconButton(
              tooltip: 'Выйти из чата',
              icon: const Icon(Icons.logout),
              onPressed: () => chat.signOut(),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: session == null
              ? _SignIn(
                  provider: widget.provider,
                  busy: chat.status == ChatStatus.connecting,
                  error: chat.error,
                  onSubmit: _signIn,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PrivacyNote(tunnelUp: widget.state.isConnected),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _history(chat),
                    ),
                    _ChatStatusBar(chat: chat),
                    const SizedBox(height: 8),
                    _Composer(
                      controller: _draft,
                      blocked: chat.status == ChatStatus.blocked,
                      replies: chat.quickReplies,
                      onSend: _send,
                      onPick: _pick,
                      onAttach: _attach,
                      onRetry: chat.retry,
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _history(ChatService chat) {
    final messages = chat.messages;
    if (messages.isEmpty) {
      return const Center(child: Text('Пока пусто. Напишите первое сообщение.'));
    }
    final self = mxLocalpart(chat.session!.userId).toLowerCase();
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) => _Bubble(
        message: messages[index],
        mine: messages[index].senderName.toLowerCase() == self,
      ),
    );
  }

  Future<void> _signIn({
    required String homeserver,
    required String user,
    required String password,
    required String roomId,
  }) async {
    final chat = _chat;
    if (chat == null) return;
    final error = await chat.signIn(
      providerId: _scopeId,
      homeserver: homeserver,
      user: user,
      password: password,
      roomId: roomId.isEmpty ? null : roomId,
    );
    if (error == null) _scrollToEnd();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error ?? 'Вход выполнен')));
  }

  Future<void> _send() async {
    final text = _draft.text;
    if (text.trim().isEmpty) return;
    _draft.clear();
    await _chat?.send(text);
    _scrollToEnd();
  }

  Future<void> _pick(QuickReply reply) async {
    await _chat?.send(reply.text);
    _scrollToEnd();
  }

  /// Отправка снимка. Отказ от выбора файла ошибкой не считается — пользователь
  /// просто передумал, поэтому сообщение показываем только на сбой отправки.
  Future<void> _attach() async {
    final chat = _chat;
    if (chat == null) return;
    final picked = await (widget.pickImage ?? pickSupportImage)();
    if (picked == null || picked.bytes.isEmpty) return;
    final error = await chat.sendImage(
      bytes: picked.bytes,
      name: picked.name,
      mimeType: imageMimeType(picked.name),
    );
    _scrollToEnd();
    if (error != null) _snack(error);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }
}

/// Приватность и маршрут трафика — обе вещи пользователь видит до отправки:
/// текст читает дежурный, а чат идёт через туннель, только если туннель поднят.
class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.tunnelUp});

  final bool tunnelUp;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Сообщения читает дежурный поддержки — не пишите пароли и данные карты. '
              'Туннель ${tunnelUp ? 'поднят: чат идёт через него' : 'выключен: чат идёт напрямую'}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка состояния: «отправлено / в очереди / нет связи / ошибка доступа».
class _ChatStatusBar extends StatelessWidget {
  const _ChatStatusBar({required this.chat});

  final ChatService chat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (text, color, icon) = switch (chat.status) {
      ChatStatus.blocked => ('Доступ к чату закончился', colors.error, Icons.lock_outline),
      ChatStatus.connecting => ('Соединение с узлом…', colors.primary, Icons.hourglass_top),
      ChatStatus.retrying => ('Нет связи — сообщения в очереди', colors.error, Icons.cloud_off),
      ChatStatus.live when chat.queued > 0 =>
        ('В очереди: ${chat.queued}', colors.primary, Icons.schedule),
      ChatStatus.live => ('Отправлено', Colors.green.shade700, Icons.done_all),
      ChatStatus.signedOut => ('Чат закрыт', colors.outline, Icons.forum_outlined),
    };

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// Сообщение в ленте: своё справа, чужое слева, у своих — статус отправки.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine});

  final ChatMessage message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fill = mine ? colors.primaryContainer : colors.surfaceContainerHighest;
    final onFill = mine ? colors.onPrimaryContainer : colors.onSurface;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .78),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine)
                Text(
                  message.senderName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colors.primary,
                  ),
                ),
              if (message.image == null)
                Text(message.body, style: TextStyle(color: onFill))
              else
                _Attachment(image: message.image!, onFill: onFill),
              const SizedBox(height: 2),
              Text(
                _status(mine),
                style: TextStyle(
                  fontSize: 11,
                  color: message.failed ? colors.error : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _status(bool mine) {
    final time = _time(message.at);
    if (!mine) return time;
    if (message.failed) return '$time · не отправлено';
    if (message.pending) return '$time · в очереди';
    return '$time · отправлено';
  }

  String _time(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}

/// Вложение в сообщении: снимок целиком, а пока он не скачался — имя файла.
class _Attachment extends StatelessWidget {
  const _Attachment({required this.image, required this.onFill});

  final ChatImage image;
  final Color onFill;

  @override
  Widget build(BuildContext context) {
    if (!image.loaded) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Загрузка снимка… ${image.name}',
              style: TextStyle(color: onFill),
            ),
          ),
        ],
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          image.bytes!,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => Text(
            'Снимок не открылся: ${image.name}',
            style: TextStyle(color: onFill),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.blocked,
    required this.onSend,
    required this.onAttach,
    required this.onRetry,
    this.replies = const [],
    this.onPick,
  });

  final TextEditingController controller;
  final bool blocked;
  final List<QuickReply> replies;
  final Future<void> Function(QuickReply)? onPick;
  final Future<void> Function() onSend;
  final Future<void> Function() onAttach;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (replies.isNotEmpty) ...[
          // Кнопки пришли из комнаты — набор задаёт провайдер, а не клиент.
          // Перенос по строкам: восемь категорий не помещаются в одну полосу.
          LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final reply in replies)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    // ActionChip не переносит длинную подпись и обрезает её,
                    // поэтому кнопка категории — TextButton в виде чипа.
                    child: TextButton(
                      key: ValueKey('quick.${reply.id}'),
                      onPressed: blocked ? null : () => onPick?.call(reply),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        side: BorderSide(color: Theme.of(context).colorScheme.outline),
                      ),
                      child: Text(reply.caption),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('draft'),
                controller: controller,
                enabled: !blocked,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Сообщение дежурному',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('attach'),
              tooltip: 'Приложить снимок',
              icon: const Icon(Icons.attach_file),
              onPressed: blocked ? null : onAttach,
            ),
            IconButton(
              tooltip: 'Отправить',
              icon: const Icon(Icons.send),
              onPressed: blocked ? null : onSend,
            ),
            if (!blocked)
              IconButton(
                tooltip: 'Повторить отправку',
                icon: const Icon(Icons.refresh),
                onPressed: onRetry,
              ),
          ],
        ),
      ],
    );
  }
}

/// Вход готовой учёткой: узел и комнату берём из подписки, если провайдер их
/// прислал. Адрес узла можно ввести руками — клиент работает с любым
/// провайдером, а своих адресов в коде нет.
class _SignIn extends StatefulWidget {
  const _SignIn({
    this.provider,
    required this.busy,
    required this.error,
    required this.onSubmit,
  });

  final Provider? provider;
  final bool busy;
  final String? error;
  final Future<void> Function({
    required String homeserver,
    required String user,
    required String password,
    required String roomId,
  }) onSubmit;

  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> {
  late final TextEditingController _homeserver =
      TextEditingController(text: widget.provider?.chatHomeserver ?? '');
  final TextEditingController _user = TextEditingController();
  final TextEditingController _password = TextEditingController();
  late final TextEditingController _room =
      TextEditingController(text: widget.provider?.chatRoomId ?? '');

  @override
  void dispose() {
    _homeserver.dispose();
    _user.dispose();
    _password.dispose();
    _room.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final missing = widget.provider?.chatHomeserver == null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text(
            'Чат поддержки',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Учётку для чата выдаёт провайдер вместе с ключом. '
            'Регистрации в приложении нет: войти можно только готовым логином '
            'и паролем. Сообщения читает дежурный поддержки.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('homeserver'),
            controller: _homeserver,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Адрес узла чата',
              hintText: 'https://узел:8448',
              border: const OutlineInputBorder(),
              helperText: missing
                  ? 'Провайдер не прислал адрес узла — введите его вручную'
                  : null,
              helperStyle: missing ? TextStyle(color: colors.error) : null,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('user'),
            controller: _user,
            decoration: const InputDecoration(
              labelText: 'Логин учётки',
              hintText: '@имя:узел',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('password'),
            obscureText: true,
            controller: _password,
            decoration: const InputDecoration(
              labelText: 'Пароль',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('room'),
            controller: _room,
            decoration: const InputDecoration(
              labelText: 'Комната (необязательно)',
              hintText: '!id:узел',
              border: OutlineInputBorder(),
            ),
          ),
          if (widget.error != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.error!,
              style: TextStyle(color: colors.error),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: widget.busy
                ? null
                : () => widget.onSubmit(
                      homeserver: _homeserver.text,
                      user: _user.text,
                      password: _password.text,
                      roomId: _room.text.trim(),
                    ),
            child: Text(widget.busy ? 'Вход…' : 'Войти в чат'),
          ),
        ],
      ),
    );
  }
}
