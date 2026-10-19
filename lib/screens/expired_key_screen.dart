import 'package:flutter/material.dart';

import '../app_state.dart';
import '../l10n/app_localizations.dart';
import '../support_chat_screen.dart';

/// Экран закончившегося пробного ключа: объясняет, что ключ истёк, и ведёт в
/// поддержку за продлением (§3.8).
///
/// Поддержка открывается внутри клиента (чат без провайдера — «первая помощь»),
/// а не глубокой ссылкой на бота: так экран остаётся нейтральным и не зашивает
/// адрес в код. Дата окончания программы — из локализованной строки.
class ExpiredKeyScreen extends StatelessWidget {
  const ExpiredKeyScreen({required this.state, this.onOpenSupport, super.key});

  final AppState state;

  /// Чем открывать поддержку. По умолчанию — внутренний чат; в испытаниях
  /// подменяется, чтобы не поднимать экран чата.
  final VoidCallback? onOpenSupport;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.expiredTitle), centerTitle: true),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_clock,
                  size: 64,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(height: 16),
                Text(
                  l.expiredBody,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l.expiredSupport,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.forum_outlined),
                  label: Text(l.expiredOpenSupport),
                  onPressed: () => _openSupport(context),
                ),
                const SizedBox(height: 16),
                Text(
                  l.expiredProgramNote,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSupport(BuildContext context) {
    final override = onOpenSupport;
    if (override != null) {
      override();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) => SupportChatScreen(state: state),
      ),
    );
  }
}
