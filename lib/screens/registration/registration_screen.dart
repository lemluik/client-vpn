import 'dart:io';

import 'package:flutter/material.dart';

import '../../about_screen.dart' show clientVersion;
import '../../app_state.dart';
import '../../l10n/app_localizations.dart';
import '../../provider.dart';
import '../../services/device_id.dart';
import '../../services/registration_api.dart';

/// Приводит логин Telegram к одному виду: убирает пробелы и ведущий «@»,
/// возвращает null, если это не похоже на имя (5–32 символа, латиница, цифры,
/// подчёркивание). Серверу экран отправляет значение с «@» впереди (§3.3).
String? normalizeTelegramLogin(String raw) {
  var value = raw.trim();
  if (value.startsWith('@')) value = value.substring(1).trim();
  if (value.length < 5 || value.length > 32) return null;
  if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(value)) return null;
  return value;
}

/// Экран подключения пробного ключа: логин Telegram, согласие с условиями и
/// запрос к точке контроля.
///
/// Микрокопия избегает слова «регистрация» — оно описывает процесс системы, а не
/// действие пользователя (§3.2). Точка контроля и имя сервиса приходят из
/// конфигурации, поэтому экран нейтрален: без конфига пробный ключ не выдаётся.
class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({
    required this.state,
    RegistrationApi? api,
    DeviceId? deviceId,
    SubscriptionFetcher? subscriptionFetch,
    super.key,
  }) : _api = api,
       _deviceId = deviceId,
       _subscriptionFetch = subscriptionFetch;

  final AppState state;

  /// Чем запрашивать ключ. По умолчанию — обмен с точкой контроля из конфига;
  /// в испытаниях подменяется заглушкой, сеть не поднимается.
  final RegistrationApi? _api;

  /// Источник идентификатора устройства. В испытаниях подменяется.
  final DeviceId? _deviceId;

  /// Чем получать подписку пробного ключа. В испытаниях подменяется.
  final SubscriptionFetcher? _subscriptionFetch;

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final TextEditingController _loginController = TextEditingController();
  bool _agreedToTerms = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _loginController.dispose();
    super.dispose();
  }

  void _notify(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// Точка контроля приходит из конфигурации; без неё (открытый клиент) пробный
  /// ключ запросить негде — сообщаем, что сервис не настроен.
  RegistrationApi _resolveApi() {
    final injected = widget._api;
    if (injected != null) return injected;
    final controlPoint = widget.state.serviceConfig.controlPoint;
    if (controlPoint == null || controlPoint.isEmpty) {
      throw RegistrationException('Сервис не настроен');
    }
    return HttpRegistrationApi(controlPoint: controlPoint);
  }

  /// Пробный ключ добавляем подпиской, а не голой ссылкой: адрес чата поддержки
  /// и учётка в нём выдаются заголовками ответа подписки, и подключение,
  /// собранное из одной ссылки, остаётся без чата навсегда. Ссылку используем
  /// только когда провайдер адреса подписки не дал.
  Future<String?> _addConnection(RegistrationResult result) {
    final url = result.subscriptionUrl;
    if (url == null || url.isEmpty) return widget.state.addFromText(result.key);
    return widget.state.addSubscription(url, fetch: widget._subscriptionFetch);
  }

  Future<void> _submit() async {
    final l = AppLocalizations.of(context);
    if (!_agreedToTerms) {
      _notify(l.registrationNeedConsent);
      return;
    }
    final login = normalizeTelegramLogin(_loginController.text);
    if (login == null) {
      _notify(l.registrationBadLogin);
      return;
    }

    setState(() => _isLoading = true);
    // Успех показываем уже на главном экране, поэтому общий ScaffoldMessenger
    // запоминаем до того, как закроем этот.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final device = DeviceData(
        deviceId: await (widget._deviceId ?? DeviceId()).get(),
        platform: Platform.operatingSystem,
        appVersion: clientVersion,
      );
      final result = await _resolveApi().register(
        telegramLogin: '@$login',
        device: device,
      );
      final error = await _addConnection(result);
      if (error != null) {
        _notify(l.registrationFailed(error));
        return;
      }
      if (!mounted) return;
      Navigator.pop(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.registrationSuccess)));
    } on RegistrationException catch (e) {
      _notify(l.registrationFailed(e.message));
    } catch (e) {
      _notify(l.registrationFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.trialConnectTitle(widget.state.serviceName)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _loginController,
                enabled: !_isLoading,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: l.registrationLoginLabel,
                  hintText: l.registrationLoginHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _agreedToTerms,
                onChanged: _isLoading
                    ? null
                    : (value) =>
                          setState(() => _agreedToTerms = value ?? false),
                title: Text(l.registrationTerms),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 16),
              FilledButton(
                // Крупная цель касания: не меньше 48 dp по высоте.
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _isLoading ? null : _submit,
                child: _isLoading
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.onPrimary,
                        ),
                      )
                    : Text(l.registrationSubmit),
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
                      child: Text(
                        l.registrationInfo,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
