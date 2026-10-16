// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'КлиентВПН';

  @override
  String get tooltipRefreshSubscription => 'Обновить подписку';

  @override
  String get tooltipAddConnection => 'Добавить подключение';

  @override
  String get tooltipSettings => 'Настройки';

  @override
  String get tooltipLog => 'Журнал';

  @override
  String get tooltipSupport => 'Поддержка';

  @override
  String get tooltipActions => 'Действия';

  @override
  String get buttonCancel => 'Отмена';

  @override
  String get buttonContinue => 'Продолжить';

  @override
  String get buttonSave => 'Сохранить';

  @override
  String get buttonAdd => 'Добавить';

  @override
  String get buttonFetch => 'Получить';

  @override
  String get switchProfileTitle => 'Сменить подключение?';

  @override
  String get switchProfileBody =>
      'Туннель будет отключён, а затем поднят заново из нового профиля.';

  @override
  String get switchRegionTitle => 'Сменить страну выхода?';

  @override
  String get switchRegionBody =>
      'Туннель будет поднят заново через другую страну. Открытые соединения прервутся.';

  @override
  String get restartForPresetTitle => 'Переподключиться?';

  @override
  String get restartForPresetBody =>
      'Новые правила работают только в поднятом заново подключении. Открытые соединения прервутся.';

  @override
  String removeProfileTitle(String name) {
    return 'Удалить «$name»?';
  }

  @override
  String get removeProfileBody =>
      'Подключение и сохранённый кэш подписки будут удалены.';

  @override
  String get renameTitle => 'Название подключения';

  @override
  String get renameHint => 'Например: рабочий';

  @override
  String get addSheetTitle => 'Добавьте подключение любого провайдера';

  @override
  String get addLinkTitle => 'Ссылка или подписка';

  @override
  String get addLinkSubtitle => 'Вставьте ключ, список ключей или подписку';

  @override
  String get addUrlTitle => 'Подписка по адресу';

  @override
  String get addUrlSubtitle => 'Обновляется сама по интервалу провайдера';

  @override
  String get addFileTitle => 'Файл config.json';

  @override
  String get addFileSubtitle => 'Для опытных: полный конфиг ядра';

  @override
  String get addLinkHint =>
      'vless://… или несколько строк, или подписка в base64';

  @override
  String get addUrlHint => 'https://провайдер.example/подписка';

  @override
  String get probeTarget => 'Точка проб';

  @override
  String get probeTargetSubtitle =>
      'Адрес, до которого клиент меряет задержку узлов';

  @override
  String get probeApplied => 'Точка проб сохранена';

  @override
  String get restartForProbeBody =>
      'Новая точка проб работает в поднятом заново подключении. Открытые соединения прервутся.';

  @override
  String get presetOff => 'Выключено';

  @override
  String get presetRu => 'Россия напрямую';

  @override
  String get presetOffSubtitle => 'Весь трафик идёт через подключение';

  @override
  String get presetOnSubtitle => 'Сайты пресета открываются мимо подключения';

  @override
  String get myRules => 'Мои правила';

  @override
  String get myRulesEmpty => 'Правил пока нет';

  @override
  String myRulesCount(int count) {
    return 'Правил: $count';
  }

  @override
  String presetSelected(String name) {
    return 'Пресет «$name» выбран';
  }

  @override
  String presetApplied(String name) {
    return 'Пресет «$name» применён';
  }

  @override
  String get subscriptionUpdated => 'Подписка обновлена';

  @override
  String get fileAdded => 'Файл добавлен';

  @override
  String get connectionAdded => 'Подключение добавлено';

  @override
  String get subscriptionAdded => 'Подписка добавлена';

  @override
  String get profileUntitled => 'Без названия';

  @override
  String get menuRename => 'Переименовать';

  @override
  String get menuDelete => 'Удалить';

  @override
  String get profileCountOne => 'Один профиль';

  @override
  String profileCountMany(int count) {
    return '$count профилей';
  }

  @override
  String regionProfileCount(int count) {
    return 'Профилей: $count';
  }

  @override
  String get subscriptionOne => 'Подписка · один профиль';

  @override
  String subscriptionMany(int count) {
    return 'Подписка · $count профилей';
  }

  @override
  String subscriptionLeftMb(String mb) {
    return 'Подписка · осталось $mb МБ';
  }

  @override
  String get regionTitle => 'Страна выхода';

  @override
  String get statusProtected => 'Защищено';

  @override
  String get statusConnecting => 'Подключение…';

  @override
  String get statusFailed => 'Сбой';

  @override
  String get statusNoLink => 'Нет связи';

  @override
  String get statusOff => 'Отключено';

  @override
  String get orbDisconnect => 'Отключить';

  @override
  String get orbConnect => 'Подключить';

  @override
  String get orbRetry => 'Подключить снова';

  @override
  String get emptyTitle => 'Быстрый доступ в интернет';

  @override
  String get emptyBody =>
      'Добавьте ключ от вашего провайдера или адрес подписки — клиент сам соберёт подключение. Своих серверов у клиента нет, он работает с любым провайдером.';

  @override
  String get emptyAddButton => 'Добавить подключение';

  @override
  String get trayShowWindow => 'Показать окно';

  @override
  String get trayQuit => 'Выйти';

  @override
  String get alreadyRunningTitle => 'Клиент уже запущен';

  @override
  String get alreadyRunningBody =>
      'Приложение открыто в другом окне. Второе окно не поднимается: два экземпляра спорят из-за системного прокси, и подключение рвётся.';

  @override
  String get alreadyRunningClose => 'Закрыть это окно';

  @override
  String get windowHiddenToTray =>
      'Клиент свёрнут в трей: подключение продолжает работать.';

  @override
  String get closeWindowSection => 'При закрытии окна';

  @override
  String get closeWindowChoiceAsk => 'Спрашивать';

  @override
  String get closeWindowChoiceTray => 'Сворачивать в трей';

  @override
  String get closeWindowChoiceQuit => 'Выходить';

  @override
  String get closeWindowTitle => 'Закрыть окно?';

  @override
  String get closeWindowBody =>
      'Свернуть в трей — подключение продолжит работать, клиент останется в трее. Выход снимет туннель и закроет приложение.';

  @override
  String get closeWindowTray => 'Свернуть в трей';

  @override
  String get closeWindowQuit => 'Выйти';

  @override
  String get closeWindowRemember => 'Запомнить выбор';

  @override
  String get aboutTitle => 'О программе';

  @override
  String aboutVersion(String version) {
    return 'Версия $version';
  }

  @override
  String get aboutRepository =>
      'Исходный код и релизы: github.com/lemluik/client-vpn';

  @override
  String get aboutLicense => 'Лицензия';

  @override
  String get aboutLicenseSubtitle => 'Mozilla Public License 2.0';

  @override
  String get aboutNotices => 'Уведомления о зависимостях';

  @override
  String get aboutNoticesSubtitle => 'Сторонние библиотеки и их лицензии';

  @override
  String get aboutNoTelemetry => 'Сбор статистики';

  @override
  String get aboutNoTelemetryBody =>
      'Клиент не собирает статистику и не отправляет данные третьим сторонам: телеметрических и аналитических библиотек в зависимостях нет.';

  @override
  String get aboutAssetMissing => 'Файл не найден в сборке';

  @override
  String get updateTitle => 'Обновление';

  @override
  String get updateSourceSubtitle =>
      'Адрес манифеста релиза. Проверка — один запрос, без идентификатора устройства и профиля';

  @override
  String get updateSourceSaved => 'Источник обновлений сохранён';

  @override
  String get updateCheck => 'Проверить обновление';

  @override
  String get updateChecking => 'Проверяю…';

  @override
  String updateFound(String version) {
    return 'Доступна версия $version';
  }

  @override
  String get updateOpen => 'Открыть загрузку';

  @override
  String get updateCopy => 'Скопировать ссылку';

  @override
  String get updateCopied => 'Ссылка скопирована';

  @override
  String get updateNoLink => 'Ссылка на эту платформу в манифесте не указана';

  @override
  String get updateOpenFailed => 'Браузер не открылся — скопируйте ссылку';

  @override
  String get settingsScreenTitle => 'Настройки';

  @override
  String get settingsThemeSection => 'Оформление';

  @override
  String get themeSystem => 'Системная';

  @override
  String get themeLight => 'Светлая';

  @override
  String get themeDark => 'Тёмная';

  @override
  String get settingsLaunchSection => 'Запуск';

  @override
  String get settingsAutoStart => 'Автозапуск с системой';

  @override
  String get settingsAutoStartAndroid =>
      'Клиент откроется сам после включения телефона';

  @override
  String get settingsAutoStartDesktop =>
      'Клиент откроется сам после входа в систему';

  @override
  String get settingsAutoStartOn => 'Клиент будет запускаться с системой';

  @override
  String get settingsAutoStartOff => 'Автозапуск выключен';

  @override
  String get settingsAutoConnect => 'Автоподключение при запуске';

  @override
  String get settingsAutoConnectPending =>
      'Станет доступно после первого успешного подключения';

  @override
  String settingsAutoConnectProfile(String name) {
    return 'Поднимаем то же подключение: $name';
  }

  @override
  String get settingsAutoConnectMissing => 'Подключение больше не найдено';

  @override
  String settingsProfilesSection(int count) {
    return 'Профили ($count)';
  }

  @override
  String get settingsProfilesEmpty =>
      'Подключений пока нет — добавьте их на главном экране.';

  @override
  String get profileKindLinks => 'Ссылки';

  @override
  String get profileKindSubscription => 'Подписка';

  @override
  String get profileKindFile => 'Файл config.json';

  @override
  String get settingsRoutingSection => 'Куда идёт трафик';

  @override
  String get settingsServiceSection => 'Обслуживание';

  @override
  String get splitHomeDirect => 'Сайты домашнего региона напрямую';

  @override
  String splitHomeDirectZones(String zones) {
    return 'Зоны: $zones. Остальное — через подключение.';
  }

  @override
  String get splitHomeDirectUnknown =>
      'Домашний регион по языку устройства не определён';

  @override
  String get splitExceptions => 'Адреса-исключения';

  @override
  String splitExceptionsCount(int direct, int tunnel) {
    return 'напрямую: $direct, в туннель: $tunnel';
  }

  @override
  String get splitExceptionsEmpty => 'Списка пока нет';

  @override
  String get splitScreenTitle => 'Раздельное туннелирование';

  @override
  String get splitHowItWorks =>
      'Адрес из списка идёт вопреки правилам домашнего региона: «напрямую» мимо туннеля или «в туннель» назло своей зоне. Ссылку можно вставить целиком — из неё возьмём только имя хоста.';

  @override
  String get splitPasteTitle => 'Вставить пачкой';

  @override
  String get splitPasteHint =>
      'По одному адресу на строку: https://example.com/path, example.org';

  @override
  String get splitDirection => 'Куда направить эти адреса';

  @override
  String get splitToDirect => 'напрямую';

  @override
  String get splitToTunnel => 'в туннель';

  @override
  String splitAdded(int added, int duplicates, int skipped) {
    return 'Добавлено $added, повторов $duplicates, пропущено $skipped';
  }

  @override
  String splitNothingAdded(int skipped) {
    return 'Ни одного адреса не разобрано, пропущено $skipped';
  }

  @override
  String get splitHostRemoved => 'Адрес убран из списка';

  @override
  String get splitHostMoved => 'Направление изменено';

  @override
  String get splitSaved => 'Список сохранён';

  @override
  String get splitApplied => 'Список применён, подключение поднято заново';

  @override
  String get splitDirectRuleTitle => 'Исключения: напрямую';

  @override
  String get splitTunnelRuleTitle => 'Исключения: в туннель';
}
