import 'dart:async';

import 'package:client_vpn/app_state.dart';
import 'package:client_vpn/deep_link.dart';
import 'package:client_vpn/profile_store.dart';
import 'package:client_vpn/vpn_config.dart';
import 'package:client_vpn/vpn_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const channelName = 'client_vpn/deep_link';

const vlessLink = 'vless://2f6bd5a1-1e73-4b1a-9d3c-000000000001@example.org:443'
    '?encryption=none&security=reality'
    '&pbk=SaMdKeySaMdKeySaMdKeySaMdKeySaMd1234'
    '&sid=ab12cd34&fp=chrome&type=tcp&sni=example.org'
    '&flow=xtls-rprx-vision#%D0%A3%D0%B7%D0%B5%D0%BB%201';

/// Ссылка, которую парсер не принимает: по ней проверяется, что содержимое
/// не утекает в журнал.
const brokenLink = 'vless://не-ссылка';

/// Ядро без процесса и без счёта: тест проверяет только путь ссылки.
class QuietCore implements VpnCore {
  final StreamController<String> _logs = StreamController<String>.broadcast();
  final StreamController<bool> _status = StreamController<bool>.broadcast();

  @override
  Stream<String> get logs => _logs.stream;

  @override
  Stream<bool> get statusChanges => _status.stream;

  @override
  bool get isRunning => false;

  @override
  String? get endpointLabel => null;

  @override
  Future<void> validate(VpnConfig config) async {}

  @override
  Future<void> start(VpnConfig config) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> recoverAfterCrash() async {}
}

/// Ответ платформы на вопрос о ссылке холодного старта.
void launchLink(String? link) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel(channelName),
    (call) async => call.method == 'takePending' ? link : null,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel(channelName),
      null,
    ),
  );
}

Future<AppState> opened({Stream<String>? links}) async {
  SharedPreferences.setMockInitialValues({});
  return AppState(
    await ProfileStore.open(),
    QuietCore(),
    // Запись служебного конфига проверена в temp_config_test.
    configWriter: (config) async => config,
    deepLinks: links,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('глубокая ссылка подключения', () {
    test('ссылка из интента запуска до подписки не теряется', () async {
      launchLink(vlessLink);
      expect(await deepLinkStream().first, vlessLink);
    });

    test('ссылка в уже открытое приложение приходит в тот же поток', () async {
      final got = <String>[];
      final subscription = deepLinkStream().listen(got.add);
      addTearDown(subscription.cancel);

      // Направленный вызов платформы: тот же байт-код, что присылает Kotlin
      // через channel.invokeMethod("link", ...).
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger.handlePlatformMessage(
        channelName,
        const StandardMethodCodec()
            .encodeMethodCall(const MethodCall('link', vlessLink)),
        (_) {},
      );

      expect(got, [vlessLink]);
    });

    test('тап по ссылке добавляет подключение и делает его активным',
        () async {
      launchLink(vlessLink);
      final state = await opened(links: deepLinkStream());
      addTearDown(state.dispose);
      await pumpEventQueue();

      expect(state.profiles, hasLength(1));
      expect(state.activeProfile?.name, 'Узел 1');
      expect(state.log, contains('Подключение добавлено по ссылке'));
    });

    test('неразобранная ссылка не создаёт профиля и не выдаёт ключ в журнал',
        () async {
      launchLink(brokenLink);
      final state = await opened(links: deepLinkStream());
      addTearDown(state.dispose);
      await pumpEventQueue();

      expect(state.profiles, isEmpty);
      final journal = state.log.join('\n');
      expect(journal, contains('Ссылка не добавлена'));
      expect(journal, isNot(contains('не-ссылка')));
      expect(journal, isNot(contains('2f6bd5a1')));
    });

    test('без ссылки приложение открывается пустым', () async {
      launchLink(null);
      final state = await opened(links: deepLinkStream());
      addTearDown(state.dispose);
      await pumpEventQueue();

      expect(state.profiles, isEmpty);
      expect(state.log, isNot(contains('по ссылке')));
    });
  });
}
