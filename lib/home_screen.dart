import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'about_screen.dart';
import 'app_state.dart';
import 'failover.dart';
import 'l10n/app_localizations.dart';
import 'log_screen.dart';
import 'profile_store.dart';
import 'provider.dart';
import 'region.dart';
import 'routing_presets.dart';
import 'rules_screen.dart';
import 'settings_screen.dart';
import 'support_chat_screen.dart';
import 'update_screen.dart';

/// Главный экран: состояние туннеля, список подключений и добавление новых.
///
/// Журнал и способ входа сырым файлом убраны отсюда: первый экран отвечает на
/// вопрос «подключено ли», а не «что пишет ядро».
class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.state, super.key});

  final AppState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onChange);
  }

  @override
  void dispose() {
    _state.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final empty = _state.profiles.isEmpty;
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.appTitle),
        centerTitle: true,
        leading: IconButton(
          tooltip: l.tooltipSettings,
          icon: const Icon(Icons.settings_outlined),
          onPressed: _openSettings,
        ),
        actions: [
          if (!empty && _state.activeProvider != null)
            IconButton(
              tooltip: l.tooltipRefreshSubscription,
              icon: const Icon(Icons.refresh),
              onPressed: _state.isBusy ? null : _refreshActive,
            ),
          IconButton(
            tooltip: l.tooltipAddConnection,
            icon: const Icon(Icons.add),
            onPressed: _state.isBusy ? null : _showAddSheet,
          ),
          IconButton(
            tooltip: l.tooltipMore,
            icon: const Icon(Icons.tune),
            onPressed: _state.isBusy ? null : _showSettingsSheet,
          ),
          IconButton(
            tooltip: l.tooltipLog,
            icon: const Icon(Icons.article_outlined),
            onPressed: _openLog,
          ),
          IconButton(
            tooltip: l.tooltipSupport,
            icon: const Icon(Icons.forum_outlined),
            onPressed: _openChat,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_state.failure != null) ...[
                _FailureCard(failure: _state.failure!),
                const SizedBox(height: 16),
              ],
              if (empty)
                Expanded(child: _EmptyState(onAdd: _showAddSheet))
              else ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: _profileList(),
                ),
                if (_state.regions.length > 1) ...[
                  const SizedBox(height: 12),
                  _RegionPicker(
                    regions: _state.regions,
                    selected: _state.activeRegion?.key,
                    onChanged: _selectRegion,
                  ),
                ],
                // Два одинаковых Spacer'а ставят диск ровно в середину
                // оставшегося места, а строка статуса остаётся у нижнего края.
                const Spacer(),
                _ConnectOrb(state: _state, onPressed: _toggle),
                const Spacer(),
              ],
              _StatusLine(state: _state),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileList() {
    final active = _state.activeProfile;

    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _state.profiles.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final profile = _state.profiles[index];
        return _ProfileCard(
          profile: profile,
          provider: _state.activeProvider?.id == profile.providerId
              ? _state.activeProvider
              : null,
          selected: profile.id == active?.id,
          onSelect: () => _select(profile.id),
          onRename: () => _rename(profile),
          onRemove: () => _remove(profile),
        );
      },
    );
  }

  Future<void> _toggle() async {
    if (_state.isConnected) {
      await _state.disconnect();
      return;
    }
    await _state.connect();
  }

  Future<void> _select(String id) async {
    if (_state.isConnected) {
      final l = AppLocalizations.of(context);
      final leave = await _confirm(
        l.switchProfileTitle,
        l.switchProfileBody,
      );
      if (!leave) return;
      await _state.disconnect();
    }
    await _state.select(id);
  }

  Future<void> _refreshActive() async {
    final l = AppLocalizations.of(context);
    final error = await _state.refreshActive();
    _notify(error ?? l.subscriptionUpdated);
  }

  /// Смена страны рвёт установленные соединения, поэтому на поднятом туннеле
  /// спрашиваем подтверждение и поднимаем туннель заново через новый путь.
  Future<void> _selectRegion(String key) async {
    if (!_state.isConnected) {
      await _state.selectRegion(key);
      return;
    }

    final l = AppLocalizations.of(context);
    final leave = await _confirm(
      l.switchRegionTitle,
      l.switchRegionBody,
    );
    if (!leave) return;
    await _state.disconnect();
    await _state.selectRegion(key);
    await _state.connect();
  }

  Future<void> _rename(StoredProfile profile) async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: profile.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.renameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l.renameHint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.buttonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l.buttonSave),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await _state.rename(profile.id, name);
  }

  Future<void> _remove(StoredProfile profile) async {
    final l = AppLocalizations.of(context);
    final confirmed = await _confirm(
      l.removeProfileTitle(profile.name),
      l.removeProfileBody,
    );
    if (!confirmed) return;
    await _state.remove(profile.id);
  }

  Future<bool> _confirm(String title, String text) async {
    final l = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.buttonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.buttonContinue),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
          builder: (context) => SettingsScreen(state: _state)),
    );
  }

  void _openLog() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (context) => LogScreen(state: _state)),
    );
  }

  /// Чат поддержки открыт для записей провайдера: узел и комнату даёт подписка,
  /// а учётку выдаёт провайдер вместе с ключом.
  void _openChat() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (context) =>
            SupportChatScreen(state: _state, provider: _state.activeProvider),
      ),
    );
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Нижняя панель добавления: способ входа выбирается на месте, контекст
  /// главного экрана не теряется.
  Future<void> _showAddSheet() async {
    final l = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  l.addSheetTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.link),
                title: Text(l.addLinkTitle),
                subtitle: Text(l.addLinkSubtitle),
                onTap: () async {
                  Navigator.pop(context);
                  await _addFromText();
                },
              ),
              ListTile(
                leading: const Icon(Icons.rss_feed),
                title: Text(l.addUrlTitle),
                subtitle: Text(l.addUrlSubtitle),
                onTap: () async {
                  Navigator.pop(context);
                  await _addSubscription();
                },
              ),
              ListTile(
                leading: const Icon(Icons.file_open),
                title: Text(l.addFileTitle),
                subtitle: Text(l.addFileSubtitle),
                onTap: () async {
                  Navigator.pop(context);
                  final error = await _state.addFile();
                  _notify(error ?? l.fileAdded);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Нижняя панель настроек: контекст главного экрана не теряется.
  ///
  /// Пресет нужен **до** первого подключения, поэтому выбор применяется сразу
  /// и поднятый туннель перезапускается, а не ждёт следующего запуска.
  Future<void> _showSettingsSheet() async {
    final l = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  l.settingsTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final preset in routingPresets)
                ListTile(
                  title: Text(_presetLabel(l, preset)),
                  subtitle: Text(
                    preset.isOff ? l.presetOffSubtitle : l.presetOnSubtitle,
                  ),
                  trailing: preset.key == _state.routingPreset.key
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    await _applyPreset(preset);
                  },
                ),
              ListTile(
                title: Text(l.myRules),
                subtitle: Text(
                  _state.manualRules.isEmpty
                      ? l.myRulesEmpty
                      : l.myRulesCount(_state.manualRules.length),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(this.context).push(
                    MaterialPageRoute(
                      builder: (_) => RulesScreen(state: _state),
                    ),
                  );
                },
              ),
              ListTile(
                title: Text(l.probeTarget),
                subtitle: Text(_state.probeEndpoint),
                onTap: () async {
                  Navigator.pop(context);
                  await _editProbeTarget();
                },
              ),
              ListTile(
                title: Text(l.updateTitle),
                subtitle: Text(l.updateSourceSubtitle),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(this.context).push(
                    MaterialPageRoute(
                      builder: (_) => const UpdateScreen(),
                    ),
                  );
                },
              ),
              if (defaultTargetPlatform == TargetPlatform.android)
                ListTile(
                  title: Text(l.tileTitle),
                  subtitle: Text(l.tileSubtitle),
                  onTap: () async {
                    Navigator.pop(context);
                    await _addTile();
                  },
                ),
              ListTile(
                title: Text(l.aboutTitle),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(this.context).push(
                    MaterialPageRoute(
                      builder: (_) => const AboutScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Системный запрос добавления плитки. На старых Android система его не
  /// принимает — там показываем текстовую инструкцию.
  Future<void> _addTile() async {
    bool added = false;
    try {
      added = await const MethodChannel('client_vpn/tunnel')
              .invokeMethod<bool>('addTile') ==
          true;
    } on Exception {
      added = false;
    }
    if (added || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).tileFallback)),
    );
  }

  /// Название пресета на языке интерфейса. Модель список не переводит:
  /// она работает до первого кадра, а язык известен только в виджете.
  String _presetLabel(AppLocalizations l, RoutingPreset preset) =>
      switch (preset.key) {
        'ru' => l.presetRu,
        'none' => l.presetOff,
        _ => preset.label,
      };

  Future<void> _applyPreset(RoutingPreset preset) async {
    if (preset.key == _state.routingPreset.key) return;

    final l = AppLocalizations.of(context);
    final label = _presetLabel(l, preset);
    if (!_state.isConnected) {
      await _state.setRoutingPreset(preset.key);
      _notify(l.presetSelected(label));
      return;
    }

    final restart = await _confirm(
      l.restartForPresetTitle,
      l.restartForPresetBody,
    );
    if (!restart) return;
    await _state.disconnect();
    await _state.setRoutingPreset(preset.key);
    await _state.connect();
    _notify(l.presetApplied(label));
  }

  /// Точка проб наблюдателя (У-3): значение вводит пользователь, нейтральное
  /// по умолчанию ничего о провайдере не сообщает.
  Future<void> _editProbeTarget() async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: _state.probeEndpoint);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.probeTarget),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.probeTargetSubtitle),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: defaultProbeEndpoint,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.buttonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l.buttonSave),
          ),
        ],
      ),
    );
    if (value == null) return;

    final error = await _state.setProbeEndpoint(value);
    if (error != null) {
      _notify(error);
      return;
    }
    if (!_state.isConnected) {
      _notify(l.probeApplied);
      return;
    }

    // Значение уже сохранено; переподключение только применяет его к каналу.
    if (await _confirm(l.restartForPresetTitle, l.restartForProbeBody)) {
      await _state.disconnect();
      await _state.connect();
    }
    _notify(l.probeApplied);
  }

  Future<void> _addFromText() async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.addLinkTitle),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            maxLines: 6,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l.addLinkHint,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.buttonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l.buttonAdd),
          ),
        ],
      ),
    );
    if (text == null) return;

    final error = await _state.addFromText(text);
    _notify(error ?? l.connectionAdded);
  }

  Future<void> _addSubscription() async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.addUrlTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: l.addUrlHint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.buttonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l.buttonFetch),
          ),
        ],
      ),
    );
    if (url == null) return;

    final error = await _state.addSubscription(url);
    _notify(error ?? l.subscriptionAdded);
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.failure});

  final Failure failure;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Card(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colors.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure.message,
                    style: TextStyle(
                      color: colors.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    failure.action,
                    style: TextStyle(color: colors.onErrorContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Круглая кнопка отняла место у объяснения: в маленьком окне текст
    // должен прокручиваться, а не выходить за границы Column.
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight,
              maxWidth: 420,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.vpn_key_outlined,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  l.emptyTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  l.emptyBody,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    label: Text(
                      l.emptyAddButton,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.onSelect,
    required this.onRename,
    required this.onRemove,
    this.provider,
  });

  final StoredProfile profile;
  final Provider? provider;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return Card(
      color:
          selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        onTap: onSelect,
        leading: Icon(_iconOf(profile.kind)),
        title: Text(
          profile.name.isEmpty ? l.profileUntitled : profile.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(_subtitleOf(l, profile, provider)),
        trailing: PopupMenuButton<String>(
          tooltip: l.tooltipActions,
          onSelected: (value) {
            if (value == 'rename') onRename();
            if (value == 'remove') onRemove();
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'rename', child: Text(l.menuRename)),
            PopupMenuItem(value: 'remove', child: Text(l.menuDelete)),
          ],
        ),
      ),
    );
  }

  IconData _iconOf(ProfileKind kind) => switch (kind) {
        ProfileKind.links => Icons.key_outlined,
        ProfileKind.subscription => Icons.rss_feed,
        ProfileKind.file => Icons.description_outlined,
      };

  String _subtitleOf(
    AppLocalizations l,
    StoredProfile profile,
    Provider? provider,
  ) {
    final count = profile.links.length;
    final usage = provider?.usage;
    final left = usage?.remaining;

    return switch (profile.kind) {
      ProfileKind.file => l.profileKindFile,
      ProfileKind.links =>
        count == 1 ? l.profileCountOne : l.profileCountMany(count),
      ProfileKind.subscription => left == null
          ? (count == 1
              ? l.subscriptionOne
              : l.subscriptionMany(count))
          : l.subscriptionLeftMb(_megabytes(left)),
    };
  }

  String _megabytes(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
}

/// Выбор страны выхода. Показывается, только когда провайдер отдаёт узлы
/// нескольких стран: подписки без регионов работают как раньше. Список
/// открывается по тапу по строке, поэтому страну выбирают до подключения.
class _RegionPicker extends StatelessWidget {
  const _RegionPicker({
    required this.regions,
    required this.selected,
    required this.onChanged,
  });

  final List<Region> regions;
  final String? selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    // Выбранный регион мог пропасть после обновления подписки: тогда показываем
    // действующий, первый, чтобы значение списка всегда совпадало с подключением.
    final current = regions.any((region) => region.key == selected)
        ? selected!
        : regions.first.key;
    final region = regions.firstWhere((r) => r.key == current);
    final l = AppLocalizations.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _openList(context, current),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.public, size: 20),
            const SizedBox(width: 8),
            Text(l.regionTitle),
            const SizedBox(width: 8),
            const Spacer(),
            Flexible(
              child: _CountryLabel(region),
            ),
            const Icon(Icons.keyboard_arrow_down, size: 20),
          ],
        ),
      ),
    );
  }

  void _openList(BuildContext context, String current) {
    final l = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(l.regionTitle),
            ),
            for (final region in regions)
              ListTile(
                title: _CountryLabel(region),
                subtitle: Text(l.regionProfileCount(region.links.length)),
                trailing:
                    region.key == current ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (region.key != current) onChanged(region.key);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Флаг и полное название страны.
///
/// Windows не рисует значки из пар региональных индикаторов: вместо флага в
/// интерфейсе остаются две буквы («EU Европа»), и с явным Segoe UI Emoji так
/// же. На Windows показываем только полное название; флаг при этом остаётся в
/// имени узла, в журнале и в подписке провайдера.
class _CountryLabel extends StatelessWidget {
  const _CountryLabel(this.region);

  final Region region;

  @override
  Widget build(BuildContext context) => Text(
        defaultTargetPlatform == TargetPlatform.windows || region.flag.isEmpty
            ? region.name
            : region.label,
        overflow: TextOverflow.ellipsis,
      );
}

/// Круглая кнопка подключения: цвет и кольцо показывают состояние,
/// жест вниз втягивает диск, как настоящая кнопка.
class _ConnectOrb extends StatefulWidget {
  const _ConnectOrb({required this.state, required this.onPressed});

  final AppState state;
  final Future<void> Function() onPressed;

  static const double _diameter = 124;

  @override
  State<_ConnectOrb> createState() => _ConnectOrbState();
}

class _ConnectOrbState extends State<_ConnectOrb> {
  bool _pressed = false;

  AppState get _state => widget.state;

  void _press(bool value) {
    if (mounted) setState(() => _pressed = value);
  }

  /// Переключение туннеля меняет сетевой путь всего устройства, поэтому нажатие
  /// подтверждается осязанием: пользователю важно почувствовать команду, когда
  /// экран не виден (карман, рука на руле).
  void _tap() {
    HapticFeedback.mediumImpact();
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final connecting = _state.state == TunnelState.connecting;
    final connected = _state.isConnected;
    final failed = _state.state == TunnelState.failure;
    final colors = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);

    // Во время подключения диск занят: canConnect уже исключает этот кадр.
    final enabled = _state.canConnect || connected;

    final (fill, ring, glyph, glow, caption) = switch (_state.state) {
      TunnelState.on => (
          colors.primary,
          colors.primary.withValues(alpha: 0.35),
          Colors.white,
          colors.primary.withValues(alpha: 0.40),
          l.orbDisconnect,
        ),
      TunnelState.connecting => (
          colors.primaryContainer,
          colors.primary.withValues(alpha: 0.55),
          colors.onPrimaryContainer,
          colors.primary.withValues(alpha: 0.18),
          l.statusConnecting,
        ),
      TunnelState.failure => (
          colors.errorContainer,
          colors.error.withValues(alpha: 0.45),
          colors.onErrorContainer,
          colors.error.withValues(alpha: 0.18),
          l.orbRetry,
        ),
      TunnelState.noLink => (
          colors.errorContainer,
          colors.error.withValues(alpha: 0.45),
          colors.onErrorContainer,
          colors.error.withValues(alpha: 0.18),
          l.orbRetry,
        ),
      TunnelState.off => (
          colors.surfaceContainerHighest,
          colors.outline,
          colors.onSurfaceVariant,
          Colors.transparent,
          l.orbConnect,
        ),
    };

    return Semantics(
      button: true,
      enabled: enabled,
      label: caption,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? _tap : null,
        onTapDown: enabled ? (_) => _press(true) : null,
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _pressed ? 0.94 : 1.0,
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                width: _ConnectOrb._diameter,
                height: _ConnectOrb._diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fill,
                  border: Border.all(color: ring, width: 4),
                  boxShadow: [
                    BoxShadow(
                      color: glow,
                      blurRadius: 28,
                      spreadRadius: _state.isConnected ? 4 : 0,
                    ),
                  ],
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (connecting)
                      SizedBox.fromSize(
                        size: const Size(
                          _ConnectOrb._diameter - 18,
                          _ConnectOrb._diameter - 18,
                        ),
                        child: CircularProgressIndicator(
                          color: glyph,
                          strokeWidth: 3,
                        ),
                      ),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Icon(
                        connecting
                            ? Icons.hourglass_top
                            : failed
                                ? Icons.refresh
                                : Icons.power_settings_new,
                        key: ValueKey(_state.state),
                        size: connecting ? 34 : 52,
                        color: glyph,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Text(
                caption,
                key: ValueKey(_state.state),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: enabled ? null : colors.outline,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final (text, color, icon) = switch (state.state) {
      TunnelState.on => (
          l.statusProtected,
          Colors.green.shade700,
          Icons.verified_user_outlined,
        ),
      TunnelState.connecting => (
          l.statusConnecting,
          Theme.of(context).colorScheme.primary,
          Icons.hourglass_top,
        ),
      TunnelState.failure => (
          l.statusFailed,
          Theme.of(context).colorScheme.error,
          Icons.error_outline,
        ),
      TunnelState.noLink => (
          l.statusNoLink,
          Theme.of(context).colorScheme.error,
          Icons.wifi_off,
        ),
      TunnelState.off => (
          l.statusOff,
          Theme.of(context).colorScheme.outline,
          Icons.shield_outlined,
        ),
    };

    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        if (state.endpoint != null && state.isConnected) ...[
          const Spacer(),
          Flexible(
            child: Text(
              state.endpoint!,
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}
