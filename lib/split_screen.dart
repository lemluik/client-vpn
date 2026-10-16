import 'package:flutter/material.dart';

import 'app_state.dart';
import 'l10n/app_localizations.dart';
import 'manual_rules.dart';
import 'routing_restart.dart';

/// Адреса-исключения для раздельного туннелирования.
///
/// Список идёт в то же хранилище, что и правила редактора: одно правило на
/// направление. Второе хранилище живёт своей жизнью и расходится с первым, и
/// пользователь получает два ответа на один вопрос о маршруте.
class SplitScreen extends StatefulWidget {
  const SplitScreen({required this.state, super.key});

  final AppState state;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  final TextEditingController _paste = TextEditingController();

  /// Куда кладём разобранные адреса: по умолчанию «напрямую».
  bool _toTunnel = false;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onChange);
  }

  @override
  void dispose() {
    _state.removeListener(_onChange);
    _paste.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final direct = _state.splitDirectHosts;
    final tunnel = _state.splitTunnelHosts;

    return Scaffold(
      appBar: AppBar(title: Text(l.splitScreenTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                l.splitHowItWorks,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            _SectionTitle(l.splitPasteTitle),
            TextField(
              key: const ValueKey('split-paste'),
              controller: _paste,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: l.splitPasteHint,
                border: const OutlineInputBorder(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: Text(
                l.splitDirection,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ),
            RadioGroup<bool>(
              groupValue: _toTunnel,
              onChanged: (value) => setState(() => _toTunnel = value ?? false),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    value: false,
                    title: Text(l.splitToDirect),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<bool>(
                    value: true,
                    title: Text(l.splitToTunnel),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const ValueKey('split-add'),
                onPressed: () => _add(l),
                icon: const Icon(Icons.add),
                label: Text(l.buttonAdd),
              ),
            ),
            _SectionTitle(l.splitExceptions),
            if (direct.isEmpty && tunnel.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                child: Text(
                  l.splitExceptionsEmpty,
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            for (final host in direct) _hostTile(l, host, toTunnel: false),
            for (final host in tunnel) _hostTile(l, host, toTunnel: true),
          ],
        ),
      ),
    );
  }

  Widget _hostTile(AppLocalizations l, String host, {required bool toTunnel}) {
    return ListTile(
      key: ValueKey('split-host-$host'),
      dense: true,
      title: Text(host),
      subtitle: Text(toTunnel ? l.splitToTunnel : l.splitToDirect),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: toTunnel ? l.splitToDirect : l.splitToTunnel,
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => _move(l, host, toTunnel: !toTunnel),
          ),
          IconButton(
            tooltip: l.menuDelete,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _remove(l, host),
          ),
        ],
      ),
    );
  }

  /// Разбор пачки и вставка в список.
  ///
  /// Счётчик честный: отдельно добавленное, отдельно уже бывшее в списке и
  /// отдельно то, из чего хост достать не удалось.
  Future<void> _add(AppLocalizations l) async {
    final parsed = parseHostBlock(_paste.text);
    if (parsed.hosts.isEmpty) {
      _notify(l.splitNothingAdded(parsed.skipped));
      return;
    }
    final direct = List.of(_state.splitDirectHosts);
    final tunnel = List.of(_state.splitTunnelHosts);
    var added = 0;
    var duplicates = parsed.duplicates;
    for (final host in parsed.hosts) {
      final target = _toTunnel ? tunnel : direct;
      final opposite = _toTunnel ? direct : tunnel;
      if (target.contains(host)) {
        duplicates++;
        continue;
      }
      // Тот же адрес в другом направлении — не новый адрес, а смена пути.
      opposite.remove(host);
      target.add(host);
      added++;
    }
    _paste.clear();
    await _apply(
      l,
      direct: direct,
      tunnel: tunnel,
      note: l.splitAdded(added, duplicates, parsed.skipped),
    );
  }

  Future<void> _move(
    AppLocalizations l,
    String host, {
    required bool toTunnel,
  }) {
    final direct = List.of(_state.splitDirectHosts)..remove(host);
    final tunnel = List.of(_state.splitTunnelHosts)..remove(host);
    (toTunnel ? tunnel : direct).add(host);
    return _apply(l, direct: direct, tunnel: tunnel, note: l.splitHostMoved);
  }

  Future<void> _remove(AppLocalizations l, String host) {
    final direct = List.of(_state.splitDirectHosts)..remove(host);
    final tunnel = List.of(_state.splitTunnelHosts)..remove(host);
    return _apply(l, direct: direct, tunnel: tunnel, note: l.splitHostRemoved);
  }

  Future<void> _apply(
    AppLocalizations l, {
    required List<String> direct,
    required List<String> tunnel,
    required String note,
  }) => applyRoutingChange(
    context,
    _state,
    l,
    change: () => _state.setSplitHosts(
      direct: direct,
      tunnel: tunnel,
      directTitle: l.splitDirectRuleTitle,
      tunnelTitle: l.splitTunnelRuleTitle,
    ),
    savedNote: note,
    appliedNote: note,
  );

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
      child: Text(
        text,
        style: TextStyle(
          color: colors.primary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}
