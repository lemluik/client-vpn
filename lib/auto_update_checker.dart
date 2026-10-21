import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'about_screen.dart';
import 'l10n/app_localizations.dart';
import 'open_link.dart';
import 'update_check.dart';
import 'update_dialog.dart';
import 'update_service.dart';
import 'windows_updater.dart';

/// Виджет автоматической проверки обновлений.
///
/// Встраивается в дерево виджетов и проверяет новую версию при старте. Установка
/// различается платформой: Android отдаёт APK системному установщику и живёт
/// дальше, Windows не может перезаписать собственный exe, поэтому закрывается,
/// подменой файлов занимается отдельно запущенный скрипт
/// ([WindowsUpdater.spawnInstaller]).
class AutoUpdateChecker extends StatefulWidget {
  const AutoUpdateChecker({super.key, this.onQuit});

  /// Полноценный выход из приложения: снять туннель и убить ядро. Нужен
  /// Windows — обновитель ждёт завершения процесса.
  final Future<void> Function()? onQuit;

  @override
  State<AutoUpdateChecker> createState() => _AutoUpdateCheckerState();
}

class _AutoUpdateCheckerState extends State<AutoUpdateChecker> {
  bool _checked = false;
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    // Проверка — через 5 секунд после старта, чтобы не конкурировать с
    // первым кадром, поднятием ядра и восстановлением подключения.
    _startTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_checked) _checkForUpdate();
    });
    _announceAppliedUpdate();
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    super.dispose();
  }

  /// Единственное видимое доказательство замкнутого цикла на Windows: после
  /// перезапуска сверяем версию с отметкой, поставленной перед выходом.
  Future<void> _announceAppliedUpdate() async {
    if (!Platform.isWindows) return;
    final applied =
        await UpdateService.instance.takePending(clientVersion);
    if (applied == null || !mounted) return;
    _notify(AppLocalizations.of(context).updateApplied(applied));
  }

  Future<void> _checkForUpdate() async {
    if (!Platform.isAndroid && !Platform.isWindows) return;

    final service = UpdateService.instance;
    if (!await service.isAutoCheckEnabled()) return;

    // «Позже» молчит неделю, чтобы диалог не превращался в шум.
    final lastDismissed = await service.getLastDismissed();
    if (lastDismissed != null &&
        DateTime.now().difference(lastDismissed).inDays < 7) {
      return;
    }

    setState(() => _checked = true);

    final prefs = await SharedPreferences.getInstance();
    final result = await checkForUpdate(
      feed: UpdateFeedStore(prefs).load(),
      currentVersion: clientVersion,
    );

    if (!mounted) return;
    final release = result.release;
    if (release == null) return;

    await service.markChecked();
    const isCritical = false; // TODO: читать из манифеста, когда появится поле critical

    if (!mounted) return;
    final shouldUpdate = await UpdateDialog.show(
      context,
      release: release,
      isCritical: isCritical,
    );

    if (!mounted) return;

    if (shouldUpdate == null) {
      await service.setAutoCheckEnabled(false);
      return;
    }
    if (!shouldUpdate) {
      await service.markDismissed();
      return;
    }

    await _downloadAndInstall(release);
  }

  Future<void> _downloadAndInstall(ReleaseInfo release) async {
    final l = AppLocalizations.of(context);
    final platform = Platform.isAndroid ? 'android' : 'windows';
    final url = release.downloadUrlFor(platform);
    if (url == null) {
      _notify(l.updateNoLink);
      return;
    }

    final cacheDir = await getTemporaryDirectory();
    if (mounted) {
      DownloadProgressDialog.show(context, 0.0, status: l.updateDownloading);
    }

    final download = await UpdateService.instance.downloadPackage(
      url: url,
      expectedSha256: release.sha256,
      checksumUrl: release.checksumUrlFor(url),
      onProgress: (progress) {
        if (mounted) {
          DownloadProgressDialog.update(context, progress,
              status: l.updateDownloading);
        }
      },
    );

    if (!mounted) return;
    DownloadProgressDialog.hide(context);

    if (!download.success) {
      _notify(download.failure == DownloadFailure.hashMismatch
          ? l.updateHashMismatch
          : l.updateDownloadFailed);
      return;
    }

    if (Platform.isAndroid) {
      await _installApk(download.path!);
      return;
    }
    await _installWindows(
      archivePath: download.path!,
      cacheDir: cacheDir,
      release: release,
      downloadUrl: url,
    );
  }

  Future<void> _installApk(String filePath) async {
    final l = AppLocalizations.of(context);
    try {
      await const MethodChannel('client_vpn/tunnel')
          .invokeMethod('installApk', {'filePath': filePath});
    } on PlatformException catch (e) {
      _notify('${l.updateInstallFailed}: ${e.message}');
    }
  }

  /// Подготовка подмены файлов и выход. После `onQuit` нас уже нет, поэтому
  /// всё, что должно пережить процесс (отметка версии, staging, скрипт),
  /// записывается до вызова.
  Future<void> _installWindows({
    required String archivePath,
    required Directory cacheDir,
    required ReleaseInfo release,
    required String downloadUrl,
  }) async {
    final l = AppLocalizations.of(context);
    DownloadProgressDialog.show(context, 0.0, status: l.updateApplying);
    final updater = await WindowsUpdater.stage(
      archivePath: archivePath,
      version: release.version,
      workRoot: cacheDir,
    );
    if (!mounted) return;
    DownloadProgressDialog.hide(context);

    if (updater == null || !await WindowsUpdater.canWriteTarget()) {
      // Либо архив не похож на сборку, либо каталог только для чтения:
      // повышенные привилегии без ведома пользователя не просим, отдаём ссылку.
      _notify(updater == null ? l.updateUnpackFailed : l.updateNoWriteAccess);
      await openExternalLink(downloadUrl);
      return;
    }

    await UpdateService.instance.markPending(release.version);
    _notify(l.updateWillRestart);
    // Сообщение должно успеть отрисоваться до закрытия окна.
    await Future.delayed(const Duration(seconds: 2));

    await updater.spawnInstaller(
      processId: pid,
      version: release.version,
    );
    await widget.onQuit?.call();
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
