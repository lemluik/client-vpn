import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'update_check.dart';

/// Диалог уведомления об обновлении.
///
/// Показывает версию, описание изменений и кнопки действий.
/// Для критических обновлений диалог модальный (нельзя закрыть).
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.release,
    required this.isCritical,
    required this.onUpdate,
    required this.onLater,
    this.onDisableAutoCheck,
  });

  final ReleaseInfo release;
  final bool isCritical;
  final VoidCallback onUpdate;
  final VoidCallback onLater;
  final VoidCallback? onDisableAutoCheck;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return PopScope(
      canPop: !isCritical,
      child: AlertDialog(
        title: Text(l.updateFound(release.version)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCritical) ...[
                const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 32),
                const SizedBox(height: 8),
                Text(
                  l.updateCritical,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
              ],
              if (release.notes.isNotEmpty) ...[
                Text(release.notes),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
        // Закрытием диалога распоряжаются колбэки: `show()` передаёт свои `pop`
        // с нужным результатом. Здесь второго `pop` быть не должно — иначе
        // первым уходит маршрут с `null`, а вторым срезается экран под диалогом.
        actions: [
          if (!isCritical && onDisableAutoCheck != null)
            TextButton(
              onPressed: onDisableAutoCheck,
              child: Text(l.updateDisableAutoCheck),
            ),
          if (!isCritical)
            TextButton(
              onPressed: onLater,
              child: Text(l.updateLater),
            ),
          FilledButton(
            onPressed: onUpdate,
            child: Text(l.updateNow),
          ),
        ],
      ),
    );
  }

  /// Показать диалог.
  static Future<bool?> show(
    BuildContext context, {
    required ReleaseInfo release,
    required bool isCritical,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: !isCritical,
      builder: (context) => UpdateDialog(
        release: release,
        isCritical: isCritical,
        onUpdate: () => Navigator.of(context).pop(true),
        onLater: () => Navigator.of(context).pop(false),
        onDisableAutoCheck: () => Navigator.of(context).pop<bool?>(null),
      ),
    );
    return result;
  }
}

/// Диалог прогресса скачивания.
class DownloadProgressDialog extends StatelessWidget {
  const DownloadProgressDialog({
    super.key,
    required this.progress,
    this.status,
  });

  final double progress;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return AlertDialog(
      title: Text(l.updateDownloading),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 16),
          Text('${(progress * 100).toStringAsFixed(0)}%'),
          if (status != null) ...[
            const SizedBox(height: 8),
            Text(status!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  /// Показать диалог прогресса.
  static void show(BuildContext context, double progress, {String? status}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => DownloadProgressDialog(
        progress: progress,
        status: status,
      ),
    );
  }

  /// Обновить прогресс.
  static void update(BuildContext context, double progress, {String? status}) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    show(context, progress, status: status);
  }

  /// Закрыть диалог.
  static void hide(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }
}
