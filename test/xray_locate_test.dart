import 'package:client_vpn/desktop_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Поиск ядра: на macOS ядро и geo-базы лежат в Contents/Resources/xray,
/// на Windows — рядом с exe.
void main() {
  test(
    'macOS: ядро и geo-базы в ресурсах бандла, затем папка разработчика',
    () {
      const app = '/Applications/client_vpn.app/Contents';
      final exe = p.join(app, 'MacOS', 'client_vpn');
      final candidates = DesktopCore.xrayCandidates(exe, macos: true);
      // разделитель берём у p.join, а не пишем «/»: тест прогоняется и на
      // рабочей машине разработчика под Windows, где p.join даёт обратную косую
      final bundled = p.join(p.dirname(p.dirname(exe)), 'Resources', 'xray');
      expect(candidates, [
        (p.join(bundled, 'xray'), bundled),
        (p.join('macos', 'xray', 'xray'), p.join('macos', 'xray')),
      ]);
    },
  );

  test('Windows: geo-базы рядом с найденным xray.exe', () {
    final exe = p.join('app', 'client_vpn.exe');
    final candidates = DesktopCore.xrayCandidates(exe, macos: false);
    expect(candidates.map((c) => c.$1), [
      p.join('app', 'xray', 'xray.exe'),
      p.join('app', 'xray.exe'),
      p.join('assets', 'xray', 'xray.exe'),
    ]);
    for (final (binary, assets) in candidates) {
      expect(assets, p.dirname(binary));
    }
  });
}
