import 'package:flutter/material.dart';

import 'app_state.dart';
import 'l10n/app_localizations.dart';

/// Меняет маршрут: на поднятом туннеле сначала спрашивает разрешение, потом
/// переподключает.
///
/// Правила читаются при сборке конфига, поэтому смена пути рвёт открытые
/// соединения. Применять это молча нельзя: пользователь уже пустил трафик в
/// один путь и узнает о другом, только когда всё оборвётся. Тот же порядок
/// держат переключатель домашнего региона, список пресетов и экран
/// исключений.
Future<void> applyRoutingChange(
  BuildContext context,
  AppState state,
  AppLocalizations l, {
  required Future<void> Function() change,
  required String savedNote,
  required String appliedNote,
}) async {
  // Вестник берём до пауз: после `await` контекст может уже не принадлежать
  // экрану, а сказать пользователю про результат всё равно надо.
  final messenger = ScaffoldMessenger.of(context);
  if (!state.isConnected) {
    await change();
    _notify(messenger, savedNote);
    return;
  }

  final restart = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.restartForPresetTitle),
      content: Text(l.restartForPresetBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.buttonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l.buttonContinue),
        ),
      ],
    ),
  );
  if (restart != true) return;

  await state.disconnect();
  await change();
  await state.connect();
  _notify(messenger, appliedNote);
}

void _notify(ScaffoldMessengerState messenger, String text) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
