import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';

/// A row of the tray context menu.
///
/// An empty `label` is a separator; clicking an item calls `onTap`.
typedef TrayMenuRow = ({String? label, void Function()? onTap});

/// What the tray controller needs from the native plugin.
///
/// A layer rather than direct plugin calls: since 0.7.0 `tray_manager` works
/// over FFI without a platform channel, so the only way to test the order of
/// calls while mounting the tray is to replace the whole native layer. The
/// previous defect (`setTitle` crashed a half-mounted tray) slipped past the
/// tests precisely because there was nothing to replace.
abstract class TrayPort {
  /// Sets the icon, tooltip and menu; `onIconClick` is a left click on the
  /// icon. Throws if the tray is unavailable.
  void mount({
    required String iconPath,
    required String tooltip,
    required List<TrayMenuRow> rows,
    required void Function() onIconClick,
  });

  /// The icon tooltip: the only way to show the state in the Windows tray.
  /// `setTitle` is not part of the interface: Windows silently ignores it,
  /// and on macOS it is separate text next to the icon.
  void setTooltip(String tooltip);

  /// Removes the icon. Idempotent: a repeated call does nothing.
  void dispose();
}

/// Native implementation: one `TrayIcon` per app.
class NativeTrayPort implements TrayPort {
  TrayIcon? _icon;
  Menu? _menu;
  Image? _image;
  final List<MenuItem> _items = [];
  final List<ListenerId> _listeners = [];
  final List<(MenuItem, ListenerId)> _itemListeners = [];

  /// macOS only: a disabled first menu row with the same text as the tooltip.
  /// A menu bar tooltip does not show while the app is in the background,
  /// which is almost always the case for a menu bar app.
  MenuItem? _statusItem;

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
    // A template image on macOS: the menu bar paints it in the system colour
    // for the light and dark appearance, like the icons of other apps.
    icon.isIconTemplate = Platform.isMacOS;
    icon.icon = image;

    icon.setTooltip(tooltip);
    icon.setContextMenu(
      _buildMenu(rows, status: Platform.isMacOS ? tooltip : null),
    );
    icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
    _listeners.add(icon.addListener((event) {
      if (event is TrayIconClickedEvent) onIconClick();
    }));
  }

  Menu _buildMenu(List<TrayMenuRow> rows, {String? status}) {
    final menu = Menu.create();
    if (menu == null) throw const TrayIconUnavailable('меню не создаётся');
    _menu = menu;
    if (status != null) {
      final item = MenuItem.createWithLabelAndType(status, MenuItemType.normal);
      if (item == null) throw const TrayIconUnavailable('пункт меню не создаётся');
      item.isEnabled = false;
      _items.add(item);
      _statusItem = item;
      menu.addItem(item);
      menu.addSeparator();
    }
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
      if (Platform.isMacOS) {
        // On macOS the click is emitted by the menu item itself, not by the
        // menu: a listener on the menu never fired, so Show window and Quit
        // did nothing. Other platforms keep the menu listener unchanged.
        final id = item.addListener((event) {
          if (event is MenuItemClickedEvent) onTap();
        });
        _itemListeners.add((item, id));
        continue;
      }
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
    _statusItem?.label = tooltip;
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
    for (final (item, id) in _itemListeners) {
      item.removeListener(id);
    }
    _itemListeners.clear();
    _statusItem = null;
    // Order matters: the icon holds the menu, so the menu is released after.
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

/// The tray did not mount: no icon, no menu or no platform support.
class TrayIconUnavailable implements Exception {
  const TrayIconUnavailable(this.reason);

  final String reason;
}

/// The system tray icon: show the window, quit, the state in the tooltip.
///
/// It is needed on top of the proxy settings: closing the window used to mean
/// dropping the connection, so the user closed the window only together with
/// the tunnel. Now closing hides to the tray, and quitting is a deliberate
/// menu action.
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

  /// Sets the icon and menu. Returns false if the tray is unavailable (for
  /// example, the icon could not be unpacked from assets): the UI then works
  /// without it, and closing the window stays a quit.
  ///
  /// The icon tooltip is `setToolTip`: the Windows implementation does not
  /// know `setTitle`, and there is nowhere else to put the state.
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

  /// The icon tooltip: the user sees the state without opening the window.
  Future<void> setTooltip(String tooltip) async {
    if (!_mounted) return;
    try {
      _port.setTooltip(tooltip);
    } catch (_) {
      // The state on the icon is cosmetic: an error here must not break the window.
    }
  }

  Future<void> unmount() async {
    _mounted = false;
    _port.dispose();
  }

  /// The native tray takes the icon as a file, not from the Flutter bundle
  /// (`LoadImage` on Windows), so the asset is unpacked to the temp directory
  /// on every launch. macOS gets a monochrome template PNG for the menu bar;
  /// other platforms keep the colour `.ico`.
  static Future<String?> _materializeIcon() async {
    final asset = Platform.isMacOS
        ? 'assets/tray/tray_macos.png'
        : 'assets/tray/tray.ico';
    try {
      final data = await rootBundle.load(asset);
      final path = p.join(
        Directory.systemTemp.path,
        'client_vpn_tray${p.extension(asset)}',
      );
      final file = File(path);
      // Always rewritten: a stale copy may be left over from another build.
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
