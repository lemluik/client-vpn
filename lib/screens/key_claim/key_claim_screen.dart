import 'dart:io';

import 'package:flutter/material.dart';

import '../../about_screen.dart' show clientVersion;
import '../../app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../services/device_id.dart';
import '../../services/key_claim_api.dart';
import '../../services/registration_api.dart' show DeviceData;

/// Экран авторецепта ключей по одноразовому коду из чата сервиса (Д2-22).
///
/// Логин Telegram не запрашивается: аутентификатор — сам код (§2, вариант а2).
/// Точка контроля приходит из конфигурации внедрения; без неё экран не
/// открывается, и функция остаётся недоступной — открытый клиент не привязан
/// к конкретному сервису.
///
/// Поведение по сетке раздела 4 спецификации:
///  * один действующий ключ — автодобавление и автоподключение;
///  * несколько — выпадающий список (имя, вход, срок, тип), истёкшие не
///    показываются; выбор создаёт профиль существующим механизмом;
///  * ни одного — «для этого аккаунта ключи не выпущены» и кнопка «повторить»,
///    сохранённые профили не трогаются;
///  * истёк между списком и подключением — «подключение закончилось» с
///    предложением нового кода.
class KeyClaimScreen extends StatefulWidget {
  const KeyClaimScreen({
    required this.state,
    KeyClaimApi? api,
    DeviceId? deviceId,
    DateTime Function()? now,
    super.key,
  }) : _api = api,
       _deviceId = deviceId,
       _now = now;

  final AppState state;

  /// Чем запрашивать список. По умолчанию — обмен с точкой контроля из
  /// конфигурации; в испытаниях подменяется заглушкой, сеть не поднимается.
  final KeyClaimApi? _api;

  /// Источник идентификатора устройства. В испытаниях подменяется.
  final DeviceId? _deviceId;

  /// Часы для проверки срока: в испытаниях подменяются, чтобы проверить
  /// истечение между списком и подключением без ожидания.
  final DateTime Function()? _now;

  @override
  State<KeyClaimScreen> createState() => _KeyClaimScreenState();
}

/// Шаг экрана: ввод кода, выбор из списка, «ключей нет», «закончилось».
enum _Step { enterCode, choose, none, expired }

class _KeyClaimScreenState extends State<KeyClaimScreen> {
  final TextEditingController _codeController = TextEditingController();
  _Step _step = _Step.enterCode;
  List<ClaimedKey> _keys = const [];
  ClaimedKey? _selected;
  bool _isLoading = false;

  DateTime _now() => (widget._now ?? DateTime.now)();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Транспорт изолирован за интерфейсом: экрану всё равно, кто отдаёт список.
  KeyClaimApi _resolveApi() {
    final injected = widget._api;
    if (injected != null) return injected;
    final controlPoint = widget.state.serviceConfig.controlPoint;
    if (controlPoint == null || controlPoint.isEmpty) {
      throw KeyClaimException('Сервис не настроен');
    }
    return HttpKeyClaimApi(controlPoint: controlPoint);
  }

  Future<void> _claim() async {
    final l = AppLocalizations.of(context);
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      _notify(l.keyClaimNeedCode);
      return;
    }

    setState(() => _isLoading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final device = DeviceData(
        deviceId: await (widget._deviceId ?? DeviceId()).get(),
        platform: Platform.operatingSystem,
        appVersion: clientVersion,
      );
      final keys = await _resolveApi().claim(code: code, device: device);
      // Истёкшие в списке не показываем (§4): сервер обязан их отсекать,
      // но и клиент не полагается на чужую аккуратность.
      final fresh = keys.where((key) => !key.isExpiredAt(_now())).toList();
      if (fresh.isEmpty) {
        setState(() {
          _step = keys.isEmpty ? _Step.none : _Step.expired;
          _keys = const [];
        });
        return;
      }
      if (fresh.length == 1) {
        // Прямое слово владельца: единственный ключ подхватывается автоматом.
        await _use(fresh.single, auto: true);
        if (!mounted) return;
        if (_step == _Step.expired) return;
        Navigator.pop(context);
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(l.keyClaimConnected(fresh.single.name))),
          );
        return;
      }
      setState(() {
        _keys = fresh;
        _selected = null;
        _step = _Step.choose;
      });
    } on KeyClaimException catch (e) {
      if (e.connectionExpired) {
        setState(() => _step = _Step.expired);
      } else {
        _notify(l.keyClaimFailed(e.message));
      }
    } catch (e) {
      _notify(l.keyClaimFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Создаёт профиль существующим механизмом и, если ключ единственный,
  /// подключает его. Новое хранилище не плодим: Region и наблюдатель
  /// работают над тем же профилем, что добавлен через `ProfileStore.addLinks`.
  Future<void> _use(ClaimedKey key, {required bool auto}) async {
    if (key.isExpiredAt(_now())) {
      // Истёк между списком и подключением: экран «закончилось» с
      // предложением нового кода, сохранённые профили не трогаются.
      setState(() => _step = _Step.expired);
      return;
    }
    final error = await widget.state.addClaimedKey(
      name: key.name,
      link: key.link,
    );
    if (error != null) throw KeyClaimException(error);
    if (auto) await widget.state.connect();
  }

  Future<void> _chooseAndConnect() async {
    final l = AppLocalizations.of(context);
    final key = _selected;
    if (key == null) {
      _notify(l.keyClaimNeedChoice);
      return;
    }
    setState(() => _isLoading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _use(key, auto: false);
      if (_step == _Step.expired) return;
      if (!mounted) return;
      Navigator.pop(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.keyClaimAdded(key.name))));
    } on KeyClaimException catch (e) {
      _notify(l.keyClaimFailed(e.message));
    } catch (e) {
      _notify(l.keyClaimFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _expiryLabel(AppLocalizations l, ClaimedKey key) {
    final at = key.expiresAt;
    if (at == null) return l.keyClaimNoExpiry;
    return '${at.day.toString().padLeft(2, '0')}.'
        '${at.month.toString().padLeft(2, '0')}.'
        '${at.year}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.keyClaimScreenTitle), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: switch (_step) {
            _Step.enterCode => _codeForm(l, theme),
            _Step.choose => _chooser(l, theme),
            _Step.none => _message(
              theme: theme,
              text: l.keyClaimNone,
              actionLabel: l.keyClaimRetry,
              onAction: () => setState(() => _step = _Step.enterCode),
            ),
            _Step.expired => _message(
              theme: theme,
              text: l.keyClaimConnectionExpired,
              actionLabel: l.keyClaimNewCode,
              onAction: () => setState(() {
                _codeController.clear();
                _step = _Step.enterCode;
              }),
            ),
          },
        ),
      ),
    );
  }

  Widget _codeForm(AppLocalizations l, ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _codeController,
        enabled: !_isLoading,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: l.keyHeaderCodeLabel,
          hintText: l.keyHeaderCodeHint,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _isLoading ? null : _claim,
        child: _isLoading
            ? SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onPrimary,
                ),
              )
            : Text(l.keyClaimSubmit),
      ),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(l.keyClaimInfo, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _chooser(AppLocalizations l, ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(l.keyClaimChooseTitle, style: theme.textTheme.titleMedium),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        key: const ValueKey('key-claim-choice'),
        hint: Text(l.keyClaimChooseHint),
        isExpanded: true,
        items: [
          for (final (index, key) in _keys.indexed)
            DropdownMenuItem<String>(
              value: '$index',
              child: Text(
                '${key.name} · '
                '${key.entryLabel.isEmpty ? l.keyClaimEntryUnknown : key.entryLabel}'
                ' · ${_expiryLabel(l, key)}'
                ' · ${key.trial ? l.keyClaimTypeTrial : l.keyClaimTypeRegular}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (value) => setState(() {
          _selected = value == null ? null : _keys[int.parse(value)];
        }),
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const ValueKey('key-claim-connect'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _isLoading ? null : _chooseAndConnect,
        child: Text(l.keyClaimConnectSelected),
      ),
    ],
  );

  Widget _message({
    required ThemeData theme,
    required String text,
    required String actionLabel,
    required VoidCallback onAction,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 24),
      Icon(Icons.portable_wifi_off, size: 40, color: theme.colorScheme.primary),
      const SizedBox(height: 16),
      Text(text, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
      const SizedBox(height: 24),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: onAction,
        child: Text(actionLabel),
      ),
    ],
  );
}
