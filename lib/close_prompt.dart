import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'settings_store.dart';

/// Запрос при закрытии окна: свернуть в трей или выйти, с памятью о выборе.
///
/// Живёт отдельно от `main.dart`, чтобы выбор действия проверялся тестом:
/// `window_manager` в тестовой сборке не отвечает.

/// Что в итоге делает закрытие — уже с учётом того, поднят ли трей.
enum ResolvedClose { hide, quit, ask }

/// Без трея прятать окно некуда, и любой выбор сводится к выходу: подключение
/// под скрытым окном без иконки осталось бы недоступным.
ResolvedClose resolveClose(CloseAction action, {required bool trayMounted}) {
  if (!trayMounted) return ResolvedClose.quit;
  return switch (action) {
    CloseAction.tray => ResolvedClose.hide,
    CloseAction.quit => ResolvedClose.quit,
    CloseAction.ask => ResolvedClose.ask,
  };
}

/// Ответ пользователя: куда свернуть окно и запоминать ли это.
class CloseChoice {
  const CloseChoice(this.action, {required this.remember});

  final CloseAction action;
  final bool remember;
}

/// Показывает запрос и ждёт ответа. `null` — пользователь закрыл сам запрос,
/// и тогда окно остаётся открытым: молчаливый выход из-за случайно нажатого
/// Esc был бы хуже лишнего клика.
Future<CloseChoice?> showClosePrompt(BuildContext context) =>
    showDialog<CloseChoice>(
      context: context,
      builder: (context) => const ClosePromptDialog(),
    );

class ClosePromptDialog extends StatefulWidget {
  const ClosePromptDialog({super.key});

  @override
  State<ClosePromptDialog> createState() => _ClosePromptDialogState();
}

class _ClosePromptDialogState extends State<ClosePromptDialog> {
  bool _remember = false;

  void _answer(CloseAction action) =>
      Navigator.pop(context, CloseChoice(action, remember: _remember));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return AlertDialog(
      title: Text(l.closeWindowTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.closeWindowBody),
          CheckboxListTile(
            key: const ValueKey('close-remember'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            title: Text(l.closeWindowRemember),
            value: _remember,
            onChanged: (value) => setState(() => _remember = value ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.buttonCancel),
        ),
        OutlinedButton(
          key: const ValueKey('close-quit'),
          onPressed: () => _answer(CloseAction.quit),
          child: Text(l.closeWindowQuit),
        ),
        FilledButton(
          key: const ValueKey('close-tray'),
          onPressed: () => _answer(CloseAction.tray),
          child: Text(l.closeWindowTray),
        ),
      ],
    );
  }
}
