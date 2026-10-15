import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';

/// Иконка в системном трее: показать окно, выйти, состояние в подсказке.
///
/// Нужна именно она, а не только реестр прокси: закрытое окно раньше означало
/// разрыв подключения, и пользователь закрывал окно только вместе с туннелем.
/// Теперь закрытие сворачивает в трей, а выход — осознанное действие из меню.
class AppTray with TrayListener {
  AppTray({required this.onShowWindow, required this.onQuit});

  final void Function() onShowWindow;
  final void Function() onQuit;

  bool _mounted = false;

  /// Ставит иконку и меню. Возвращает false, если трей недоступен (например,
  /// иконку не удалось распаковать из assets) — интерфейс тогда работает без
  /// него, а закрытие окна остаётся выходом.
  Future<bool> mount({
    required String tooltip,
    required String showLabel,
    required String quitLabel,
  }) async {
    final iconPath = await _materializeIcon();
    if (iconPath == null) return false;

    trayManager.addListener(this);
    await trayManager.setIcon(iconPath);
    await trayManager.setTitle(tooltip);
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'show',
            label: showLabel,
            onClick: (_) => onShowWindow(),
          ),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: quitLabel, onClick: (_) => onQuit()),
        ],
      ),
    );
    _mounted = true;
    return true;
  }

  /// Подсказка на иконке: пользователь видит состояние, не открывая окно.
  Future<void> setTooltip(String tooltip) async {
    if (_mounted) await trayManager.setTitle(tooltip);
  }

  Future<void> unmount() async {
    if (!_mounted) return;
    _mounted = false;
    trayManager.removeListener(this);
    await trayManager.destroy();
  }

  @override
  void onTrayIconMouseDown() => onShowWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  /// `LoadImage` на Windows берёт иконку файлом, а не из бандла Flutter,
  /// поэтому asset выгружается в временный каталог при каждом запуске.
  static Future<String?> _materializeIcon() async {
    try {
      final data = await rootBundle.load('assets/tray/tray.ico');
      final path = p.join(Directory.systemTemp.path, 'client_vpn_tray.ico');
      final file = File(path);
      // Файл переписывается всегда: старый кэш мог остаться от другой сборки.
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return file.absolute.path;
    } catch (_) {
      return null;
    }
  }
}
