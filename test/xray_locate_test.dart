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
      final candidates = DesktopCore.xrayCandidates(
        '$app/MacOS/client_vpn',
        macos: true,
      );
      expect(candidates, [
        ('$app/Resources/xray/xray', '$app/Resources/xray'),
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
