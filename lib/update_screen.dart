import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_metadata.dart';
import 'failover.dart' show probeEndpointError;
import 'l10n/app_localizations.dart';
import 'open_link.dart';
import 'services/service_config.dart';
import 'update_check.dart';

/// Экран ручной проверки обновления (этап R2.5, позиция 31 перечня §20.1).
///
/// Источник, сравнение версий и тексты ошибок живут в `update_check.dart`,
/// здесь — поле адреса, кнопка и результат. Этот экран ничего не устанавливает:
/// автообновление с диалогом и подменой файлов — `auto_update_checker.dart`, а
/// сюда приходят за ссылкой вручную, в том числе когда автоматическая установка
/// невозможна (каталог только для чтения).
///
/// Канал и ключ проверки подписи берутся из конфигурации сборки, а не из
/// введённого адреса: вставленная ссылка на публичный репозиторий не переводит
/// закрытую сборку на открытый пакет.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final TextEditingController _source = TextEditingController(
    text: defaultUpdateFeed,
  );
  UpdateFeedStore? _store;
  ServiceConfig? _config;
  AppMetadata? _installed;
  bool _checking = false;
  UpdateResult? _result;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final config = await ServiceConfig.load();
    final installed = AppMetadata.cached ?? await AppMetadata.load();
    if (!mounted) return;
    setState(() {
      _config = config;
      _installed = installed;
      _store = UpdateFeedStore(prefs, configuredFeed: config.updateFeed);
      _source.text = _store!.load();
    });
  }

  UpdateSource _resolve(String feed) =>
      resolveUpdateSource(userFeed: feed, config: _config);

  Future<void> _check() async {
    final typed = _source.text.trim();
    final error = probeEndpointError(typed);
    if (error != null) {
      setState(() => _result = UpdateResult.message(error));
      return;
    }

    setState(() {
      _checking = true;
      _result = null;
    });
    await _store?.save(typed);
    final source = _resolve(typed);
    final installed = _installed ?? await AppMetadata.load();
    final result = await checkForUpdate(
      feed: source.feed,
      installed: installed,
      channel: source.channel,
      publicKey: source.publicKey,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final installed = _installed;
    final own = _resolve(_source.text).isOwn;
    final version = (installed == null || !installed.isKnown)
        ? l.aboutVersionUnknown
        : l.aboutVersion(installed.versionName);

    return Scaffold(
      appBar: AppBar(title: Text(l.updateTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            Text(version),
            const SizedBox(height: 20),
            TextField(
              controller: _source,
              enabled: !_checking,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l.updateTitle,
                helperText: own ? l.updateChannelClosed : l.updateSourceSubtitle,
                helperMaxLines: 3,
                hintText: defaultUpdateFeed,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _checking ? null : _check,
              icon: const Icon(Icons.system_update_alt),
              label: Text(_checking ? l.updateChecking : l.updateCheck),
            ),
            const SizedBox(height: 16),
            _resultBlock(l),
          ],
        ),
      ),
    );
  }

  Widget _resultBlock(AppLocalizations l) {
    if (_checking) return const Center(child: CircularProgressIndicator());
    final result = _result;
    if (result == null) return const SizedBox.shrink();

    final release = result.release;
    if (release == null) return Text(result.error!);

    final own = _resolve(_source.text).isOwn;
    final url = release.downloadUrlFor(
      currentPlatformName(),
      anyAsLast: !own && !Platform.isMacOS,
      strict: own,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.updateFound(release.version),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        if (release.notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(release.notes),
        ],
        const SizedBox(height: 12),
        if (url == null)
          Text(l.updateNoLink)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _open(url),
                icon: const Icon(Icons.open_in_new),
                label: Text(l.updateOpen),
              ),
              OutlinedButton.icon(
                onPressed: () => _copy(url),
                icon: const Icon(Icons.copy),
                label: Text(l.updateCopy),
              ),
            ],
          ),
      ],
    );
  }

  /// Открыли — хорошо; не открыли — просим скопировать, ссылку видно на экране.
  Future<void> _open(String url) async {
    final l = AppLocalizations.of(context);
    if (await openExternalLink(url)) return;
    if (mounted) _notify(l.updateOpenFailed);
  }

  Future<void> _copy(String url) async {
    final l = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) _notify(l.updateCopied);
  }

  void _notify(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}