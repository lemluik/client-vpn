import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_metadata.dart';
import 'l10n/app_localizations.dart';

/// Экран «О программе» (позиция 18, пункт У-6): лицензия клиента, файлы LICENSE и
/// NOTICE и заявление об отсутствии телеметрии (позиция 16, пункт У-5).
///
/// Версия читается из метаданных установленной сборки, а не из константы в коде:
/// константа расходилась с pubspec и экран показывал не ту версию, что стоит у
/// пользователя.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  AppMetadata? _meta = AppMetadata.cached;

  @override
  void initState() {
    super.initState();
    if (_meta == null) unawaited(_load());
  }

  Future<void> _load() async {
    final meta = await AppMetadata.load();
    if (mounted) setState(() => _meta = meta);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final meta = _meta;
    final version = (meta == null || !meta.isKnown)
        ? l.aboutVersionUnknown
        : l.aboutVersion(meta.versionName);
    return Scaffold(
      appBar: AppBar(title: Text(l.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            title: Text(version),
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
