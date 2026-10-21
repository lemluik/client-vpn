import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'l10n/app_localizations.dart';

/// Версия на экране «О программе». Тест `test/about_test.dart` сверяет строку с
/// `pubspec.yaml`, чтобы экран не врал после релиза.
const String clientVersion = '0.4.1';

/// Экран «О программе» (позиция 18, пункт У-6): лицензия клиента, файлы LICENSE и
/// NOTICE и заявление об отсутствии телеметрии (позиция 16, пункт У-5).
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            title: Text(l.aboutVersion(clientVersion)),
            subtitle: Text(l.aboutRepository),
          ),
          ListTile(
            title: Text(l.aboutLicense),
            subtitle: Text(l.aboutLicenseSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openAsset(context, l.aboutLicense, 'LICENSE'),
          ),
          ListTile(
            title: Text(l.aboutNotices),
            subtitle: Text(l.aboutNoticesSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openAsset(context, l.aboutNotices, 'NOTICE'),
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l.aboutNoTelemetry),
            subtitle: Text(l.aboutNoTelemetryBody),
          ),
        ],
      ),
    );
  }

  void _openAsset(BuildContext context, String title, String asset) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _AssetTextScreen(title: title, asset: asset),
      ),
    );
  }
}

/// Текст лицензионного файла целиком: пользователь может прочитать его, не
/// выходя из приложения, и скопировать.
class _AssetTextScreen extends StatelessWidget {
  const _AssetTextScreen({required this.title, required this.asset});

  final String title;
  final String asset;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(asset),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text(l.aboutAssetMissing));
          }
          final text = snapshot.data;
          if (text == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          );
        },
      ),
    );
  }
}
