import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'about_screen.dart' show clientVersion;
import 'failover.dart' show probeEndpointError;
import 'l10n/app_localizations.dart';
import 'open_link.dart';
import 'update_check.dart';

/// Экран ручной проверки обновления (этап R2.5, позиция 31 перечня §20.1).
///
/// Источник, сравнение версий и тексты ошибок живут в `update_check.dart`,
/// здесь — поле адреса, кнопка и результат. Этот экран ничего не устанавливает:
/// автообновление с диалогом и подменой файлов — `auto_update_checker.dart`, а
/// сюда приходят за ссылкой вручную, в том числе когда автоматическая установка
/// невозможна (каталог только для чтения).
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
    if (!mounted) return;
    setState(() => _store = UpdateFeedStore(prefs));
    _source.text = _store!.load();
  }

  Future<void> _check() async {
    final error = probeEndpointError(_source.text);
    if (error != null) {
      setState(() => _result = UpdateResult.message(error));
      return;
    }

    setState(() {
      _checking = true;
      _result = null;
    });
    await _store?.save(_source.text);
    final result = await checkForUpdate(
      feed: _source.text,
      currentVersion: clientVersion,
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

    return Scaffold(
      appBar: AppBar(title: Text(l.updateTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            Text(l.aboutVersion(clientVersion)),
            const SizedBox(height: 20),
            TextField(
              controller: _source,
              enabled: !_checking,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: l.updateTitle,
                helperText: l.updateSourceSubtitle,
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

    final url = Platform.isMacOS
        ? release.downloadUrlFor('macos', anyAsLast: false)
        : release.downloadUrlFor(Platform.isAndroid ? 'android' : 'windows');

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
