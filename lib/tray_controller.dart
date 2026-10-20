import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';

/// Строка контекстного меню трея.
///
/// Пустая `label` — разделитель; клик по пункту вызывает `onTap`.
typedef TrayMenuRow = ({String? label, void Function()? onTap});

/// То, что трей-контроллер требует от нативного плагина.
///
/// Нужен именно слой, а не прямые вызовы плагина: с 0.7.0 `tray_manager`
/// работает через FFI без платформенного канала, поэтому единственный способ
/// проверить порядок вызовов на подъёме трея — подменить весь нативный слой.
/// Прошлый дефект (`setTitle` ронял трей на полу-подъёме) тесты не поймали
/// именно потому, что подменять было нечего.
abstract class TrayPort {
  /// Ставит иконку, подсказку и меню; `onIconClick` — левый клик по иконке.
  /// Бросает исключение, если трей недоступен.
  void mount({
    required String iconPath,
    required String tooltip,
    required List<TrayMenuRow> rows,
    required void Function() onIconClick,
  });

  /// Подсказка на иконке: единственный способ показать состояние трею
  /// на Windows. `setTitle` в интерфейс не входит — на Windows он
  /// игнорируется молча, а на macOS это отдельный текст рядом с иконкой.
  void setTooltip(String tooltip);

  /// Снимает иконку. Идемпотентен: повторный вызов ничего не делает.
  void dispose();
}

/// Нативная реализация: один `TrayIcon` на приложение.
class NativeTrayPort implements TrayPort {
  TrayIcon? _icon;
  Menu? _menu;
  Image? _image;
  final List<MenuItem> _items = [];
  final List<ListenerId> _listeners = [];

  @override
  void mount({
    required String iconPath,
    required String tooltip,
    required List<TrayMenuRow> rows,
    required void Function() onIconClick,
  }) {
    if (_icon != null) throw StateError('трей уже поднят');

    final image = Image.fromFile(iconPath);
    if (image == null) throw const TrayIconUnavailable('иконка не читается');
    final icon = TrayIcon.create();
    if (icon == null) throw const TrayIconUnavailable('платформа не даёт трей');
    _image = image;
    _icon = icon;
    icon.icon = image;

    icon.setTooltip(tooltip);
    icon.setContextMenu(_buildMenu(rows));
    icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
    _listeners.add(icon.addListener((event) {
      if (event is TrayIconClickedEvent) onIconClick();
    }));
  }

  Menu _buildMenu(List<TrayMenuRow> rows) {
    final menu = Menu.create();
    if (menu == null) throw const TrayIconUnavailable('меню не создаётся');
    _menu = menu;
    for (final row in rows) {
      final label = row.label;
      if (label == null) {
        menu.addSeparator();
        continue;
      }
      final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
      if (item == null) throw const TrayIconUnavailable('пункт меню не создаётся');
      _items.add(item);
      menu.addItem(item);
      final onTap = row.onTap;
      if (onTap == null) continue;
      final id = item.id;
      menu.addListener((event) {
        if (event is MenuItemClickedEvent && event.itemId == id) onTap();
      });
    }
    return menu;
  }

  @override
  void setTooltip(String tooltip) {
    _icon?.setTooltip(tooltip);
  }

  @override
  void dispose() {
    final icon = _icon;
    _icon = null;
    if (icon != null) {
      for (final id in _listeners) {
        icon.removeListener(id);
      }
      _listeners.clear();
      icon.setContextMenu(null);
      icon.dispose();
    }
    // Порядок важен: иконка держит меню, поэтому меню освобождаем после.
    for (final item in _items) {
      item.dispose();
    }
    _items.clear();
    _menu?.dispose();
    _menu = null;
    _image?.dispose();
    _image = null;
  }
}

/// Трей не поднялся: нет иконки, меню или поддержки платформы.
class TrayIconUnavailable implements Exception {
  const TrayIconUnavailable(this.reason);

  final String reason;
}

/// Иконка в системном трее: показать окно, выйти, состояние в подсказке.
///
/// Нужна именно она, а не только реестр прокси: закрытое окно раньше означало
/// разрыв подключения, и пользователь закрывал окно только вместе с туннелем.
/// Теперь закрытие сворачивает в трей, а выход — осознанное действие из меню.
class AppTray {
  AppTray({
    required this.onShowWindow,
    required this.onQuit,
    TrayPort? port,
  }) : _port = port ?? NativeTrayPort();

  final void Function() onShowWindow;
  final void Function() onQuit;
  final TrayPort _port;

  bool _mounted = false;

  /// Ставит иконку и меню. Возвращает false, если трей недоступен (например,
  /// иконку не удалось распаковать из assets) — интерфейс тогда работает без
  /// него, а закрытие окна остаётся выходом.
  ///
  /// Подсказка на иконке — это `setToolTip`: Windows-реализация не знает
  /// `setTitle` и состояние вешать больше некуда.
  Future<bool> mount({
    required String tooltip,
    required String showLabel,
    required String quitLabel,
  }) async {
    final iconPath = await _materializeIcon();
    if (iconPath == null) return false;

    try {
      _port.mount(
        iconPath: iconPath,
        tooltip: tooltip,
        rows: [
          (label: showLabel, onTap: onShowWindow),
          (label: null, onTap: null),
          (label: quitLabel, onTap: onQuit),
        ],
        onIconClick: onShowWindow,
      );
    } catch (_) {
      await unmount();
      return false;
    }
    _mounted = true;
    return true;
  }

  /// Подсказка на иконке: пользователь видит состояние, не открывая окно.
  Future<void> setTooltip(String tooltip) async {
    if (!_mounted) return;
    try {
      _port.setTooltip(tooltip);
    } catch (_) {
      // Состояние на иконке — косметика: ошибка здесь не должна ронять окно.
    }
  }

  Future<void> unmount() async {
    _mounted = false;
    _port.dispose();
  }

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
