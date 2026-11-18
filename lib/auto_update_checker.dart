import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_metadata.dart';
import 'l10n/app_localizations.dart';
import 'open_link.dart';
import 'services/service_config.dart';
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
    final installed = AppMetadata.cached ?? await AppMetadata.load();
    final applied =
        await UpdateService.instance.takePending(installed.versionName);
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
    final config = await ServiceConfig.load();
    final source = resolveUpdateSource(
      userFeed: UpdateFeedStore(prefs, configuredFeed: config.updateFeed).load(),
      config: config,
    );
    final installed = AppMetadata.cached ?? await AppMetadata.load();
    final result = await checkForUpdate(
      feed: source.feed,
      installed: installed,
      channel: source.channel,
      publicKey: source.publicKey,
    );

    if (!mounted) return;
    final release = result.release;
    if (release == null) return;

    await service.markChecked();
    final isCritical = release.critical;

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

    await _downloadAndInstall(release, source);
  }

  Future<void> _downloadAndInstall(
    ReleaseInfo release,
    UpdateSource source,
  ) async {
    final l = AppLocalizations.of(context);
    final platform = currentPlatformName();
    // Закрытый канал: только сборка своей платформы и только с суммой.
    final url = release.downloadUrlFor(
      platform,
      anyAsLast: !source.isOwn,
      strict: source.isOwn,
    );
    if (url == null) {
      _notify(l.updateNoLink);
      return;
    }
    final sum = release.sha256For(platform);
    if (source.isOwn && sum == null) {
      _notify(l.updateNoChecksum);
      return;
    }

    final cacheDir = await getTemporaryDirectory();
    if (mounted) {
      DownloadProgressDialog.show(context, 0.0, status: l.updateDownloading);
    }

    final download = await UpdateService.instance.downloadPackage(
      url: url,
      expectedSha256: sum,
      checksumUrl: release.checksumUrlFor(url),
      requireChecksum: source.isOwn,
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
      _notify(switch (download.failure) {
        DownloadFailure.hashMismatch => l.updateHashMismatch,
        DownloadFailure.noChecksum => l.updateNoChecksum,
        _ => l.updateDownloadFailed,
      });
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
