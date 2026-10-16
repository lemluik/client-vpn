import 'package:client_vpn/tray_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Подмена всего нативного слоя трея.
///
/// Нужна именно подмена слоя, а не канала: с 0.7.0 `tray_manager` говорит с
/// системой через FFI, платформенного канала больше нет, и прошлый дефект
/// (`setTitle` ронял трей на полу-подъёме) тесты проглядели именно потому,
/// что перехватывать было нечего. Здесь записывается каждый вызов, а отказ
/// включается по имени.
class FakeTrayPort implements TrayPort {
  FakeTrayPort({this.failOn});

  /// Вызов, который должен бросить исключение: `mount`, `icon`, `tooltip`
  /// или `menu`.
  final String? failOn;

  final List<String> calls = [];
  final List<TrayMenuRow> rows = [];
  String? tooltip;
  String? iconPath;
  void Function()? onIconClick;
  int disposeCount = 0;

  bool get mounted => iconPath != null && disposeCount == 0;

  @override
  void mount({
    required String iconPath,
    required String tooltip,
    required List<TrayMenuRow> rows,
    required void Function() onIconClick,
  }) {
    calls.add('mount');
    if (failOn == 'mount') throw const TrayIconUnavailable('трей недоступен');
    this.iconPath = iconPath;
    calls.add('setIcon');
    if (failOn == 'icon') throw const TrayIconUnavailable('иконка не читается');
    this.tooltip = tooltip;
    calls.add('setTooltip');
    if (failOn == 'tooltip') throw const TrayIconUnavailable('нет подсказки');
    this.rows
      ..clear()
      ..addAll(rows);
    calls.add('setContextMenu');
    if (failOn == 'menu') throw const TrayIconUnavailable('меню не создаётся');
    calls.add('addListener');
    this.onIconClick = onIconClick;
  }

  @override
  void setTooltip(String tooltip) {
    calls.add('setTooltip');
    this.tooltip = tooltip;
  }

  @override
  void dispose() {
    calls.add('dispose');
    disposeCount++;
    iconPath = null;
    tooltip = null;
    rows.clear();
    onIconClick = null;
  }
}

/// Порт, который поднимается, но отказывает на подсказке состояния.
class _BrokenTooltipPort implements TrayPort {
  bool threw = false;

  @override
  void mount({
    required String iconPath,
    required String tooltip,
    required List<TrayMenuRow> rows,
    required void Function() onIconClick,
  }) {}

  @override
  void setTooltip(String tooltip) {
    threw = true;
    throw const TrayIconUnavailable('нативный вызов отказал');
  }

  @override
  void dispose() {}
}

AppTray _tray(
  TrayPort port, {
  void Function()? onShowWindow,
  void Function()? onQuit,
}) => AppTray(
  onShowWindow: onShowWindow ?? () {},
  onQuit: onQuit ?? () {},
  port: port,
);

/// Поднимает трей теми же словами, что и `main.dart`.
Future<bool> _mountOn(
  AppTray tray, {
  String tooltip = 'КлиентВПН — отключено',
}) => tray.mount(
  tooltip: tooltip,
  showLabel: 'Показать окно',
  quitLabel: 'Выйти',
);

Future<bool> _mount(
  TrayPort port, {
  void Function()? onShowWindow,
  void Function()? onQuit,
}) => _mountOn(_tray(port, onShowWindow: onShowWindow, onQuit: onQuit));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('подъём трея', () {
    test('иконка, подсказка и меню ставятся по очереди', () async {
      final port = FakeTrayPort();

      expect(await _mount(port), isTrue);

      expect(port.calls, [
        'mount',
        'setIcon',
        'setTooltip',
        'setContextMenu',
        'addListener',
      ]);
      expect(port.iconPath, endsWith('client_vpn_tray.ico'));
      expect(port.tooltip, 'КлиентВПН — отключено');
    });

    test('меню — два пункта и разделитель между ними', () async {
      final port = FakeTrayPort();
      await _mount(port);

      expect(
        port.rows.map((row) => row.label).toList(),
        ['Показать окно', null, 'Выйти'],
      );
      expect(port.rows[1].onTap, isNull);
    });

    test(
      'сбой подсказки при подъёме не оставляет трей наполовину поднятым',
      () async {
        // Так и было в живой сборке 16.10: отказ нативного вызова оставлял
        // иконку без меню, и закрытие окна молча выходило из приложения.
        final port = FakeTrayPort(failOn: 'tooltip');

        expect(await _mount(port), isFalse);

        expect(port.mounted, isFalse);
        expect(port.calls, contains('dispose'));
        expect(port.iconPath, isNull);
      },
    );

    test('сбой иконки, меню или самого подъёма даёт false и снятие', () async {
      for (final failOn in ['icon', 'menu', 'mount']) {
        final port = FakeTrayPort(failOn: failOn);

        expect(await _mount(port), isFalse, reason: failOn);
        expect(port.calls, contains('dispose'), reason: failOn);
        expect(port.mounted, isFalse, reason: failOn);
      }
    });

    test('клик по иконке и по пунктам меню ведут в нужные действия', () async {
      var shown = 0;
      var quit = 0;
      final port = FakeTrayPort();

      await _mount(port, onShowWindow: () => shown++, onQuit: () => quit++);

      port.onIconClick!();
      port.rows[0].onTap!();
      port.rows[2].onTap!();

      expect(shown, 2);
      expect(quit, 1);
    });
  });

  group('подсказка состояния', () {
    test('состояние уходит в setTooltip, а не в setTitle', () async {
      // Windows знает только `setToolTip`: `setTitle` — текст для macOS,
      // и состояние на нём висеть не может.
      final port = FakeTrayPort();
      final tray = _tray(port);
      expect(await _mountOn(tray), isTrue);
      port.calls.clear();

      await tray.setTooltip('КлиентВПН — подключено');

      expect(port.calls, ['setTooltip']);
      expect(port.calls, isNot(contains('setTitle')));
      expect(port.tooltip, 'КлиентВПН — подключено');
    });

    test('без поднятого трея подсказка никуда не идёт', () async {
      final port = FakeTrayPort();
      final tray = _tray(port);

      await tray.setTooltip('КлиентВПН — подключено');

      expect(port.calls, isEmpty);
    });

    test('отказ нативной подсказки не роняет приложение', () async {
      final port = _BrokenTooltipPort();
      final tray = _tray(port);
      await tray.mount(
        tooltip: 'КлиентВПН — отключено',
        showLabel: 'Показать окно',
        quitLabel: 'Выйти',
      );

      await tray.setTooltip('КлиентВПН — подключено');

      expect(port.threw, isTrue);
    });
  });

  group('снятие трея', () {
    test('unmount идемпотентен, после него трей снова поднимается', () async {
      final port = FakeTrayPort();
      final tray = _tray(port);
      expect(await _mountOn(tray), isTrue);

      await tray.unmount();
      await tray.unmount();
      expect(port.disposeCount, 2);
      expect(port.mounted, isFalse);

      port.calls.clear();
      await tray.setTooltip('КлиентВПН — отключено');
      expect(port.calls, isEmpty);

      expect(await _mountOn(tray), isTrue);
    });

    test('unmount на неподнятом трее безопасен', () async {
      final port = FakeTrayPort();
      final tray = _tray(port);

      await tray.unmount();

      expect(port.disposeCount, 1);
    });
  });
}
