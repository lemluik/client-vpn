import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In ru, this message translates to:
  /// **'КлиентВПН'**
  String get appTitle;

  /// No description provided for @tooltipRefreshSubscription.
  ///
  /// In ru, this message translates to:
  /// **'Обновить подписку'**
  String get tooltipRefreshSubscription;

  /// No description provided for @tooltipAddConnection.
  ///
  /// In ru, this message translates to:
  /// **'Добавить подключение'**
  String get tooltipAddConnection;

  /// No description provided for @tooltipSettings.
  ///
  /// In ru, this message translates to:
  /// **'Настройки'**
  String get tooltipSettings;

  /// No description provided for @tooltipMore.
  ///
  /// In ru, this message translates to:
  /// **'Дополнительно'**
  String get tooltipMore;

  /// No description provided for @tooltipLog.
  ///
  /// In ru, this message translates to:
  /// **'Журнал'**
  String get tooltipLog;

  /// No description provided for @tooltipSupport.
  ///
  /// In ru, this message translates to:
  /// **'Поддержка'**
  String get tooltipSupport;

  /// No description provided for @tooltipActions.
  ///
  /// In ru, this message translates to:
  /// **'Действия'**
  String get tooltipActions;

  /// No description provided for @buttonCancel.
  ///
  /// In ru, this message translates to:
  /// **'Отмена'**
  String get buttonCancel;

  /// No description provided for @buttonContinue.
  ///
  /// In ru, this message translates to:
  /// **'Продолжить'**
  String get buttonContinue;

  /// No description provided for @buttonSave.
  ///
  /// In ru, this message translates to:
  /// **'Сохранить'**
  String get buttonSave;

  /// No description provided for @buttonAdd.
  ///
  /// In ru, this message translates to:
  /// **'Добавить'**
  String get buttonAdd;

  /// No description provided for @buttonFetch.
  ///
  /// In ru, this message translates to:
  /// **'Получить'**
  String get buttonFetch;

  /// No description provided for @switchProfileTitle.
  ///
  /// In ru, this message translates to:
  /// **'Сменить подключение?'**
  String get switchProfileTitle;

  /// No description provided for @switchProfileBody.
  ///
  /// In ru, this message translates to:
  /// **'Туннель будет отключён, а затем поднят заново из нового профиля.'**
  String get switchProfileBody;

  /// No description provided for @switchRegionTitle.
  ///
  /// In ru, this message translates to:
  /// **'Сменить страну выхода?'**
  String get switchRegionTitle;

  /// No description provided for @switchRegionBody.
  ///
  /// In ru, this message translates to:
  /// **'Туннель будет поднят заново через другую страну. Открытые соединения прервутся.'**
  String get switchRegionBody;

  /// No description provided for @restartForPresetTitle.
  ///
  /// In ru, this message translates to:
  /// **'Переподключиться?'**
  String get restartForPresetTitle;

  /// No description provided for @restartForPresetBody.
  ///
  /// In ru, this message translates to:
  /// **'Новые правила работают только в поднятом заново подключении. Открытые соединения прервутся.'**
  String get restartForPresetBody;

  /// No description provided for @removeProfileTitle.
  ///
  /// In ru, this message translates to:
  /// **'Удалить «{name}»?'**
  String removeProfileTitle(String name);

  /// No description provided for @removeProfileBody.
  ///
  /// In ru, this message translates to:
  /// **'Подключение и сохранённый кэш подписки будут удалены.'**
  String get removeProfileBody;

  /// No description provided for @renameTitle.
  ///
  /// In ru, this message translates to:
  /// **'Название подключения'**
  String get renameTitle;

  /// No description provided for @renameHint.
  ///
  /// In ru, this message translates to:
  /// **'Например: рабочий'**
  String get renameHint;

  /// No description provided for @addSheetTitle.
  ///
  /// In ru, this message translates to:
  /// **'Добавьте подключение любого провайдера'**
  String get addSheetTitle;

  /// No description provided for @addLinkTitle.
  ///
  /// In ru, this message translates to:
  /// **'Ссылка или подписка'**
  String get addLinkTitle;

  /// No description provided for @addLinkSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Вставьте ключ, список ключей или подписку'**
  String get addLinkSubtitle;

  /// No description provided for @addUrlTitle.
  ///
  /// In ru, this message translates to:
  /// **'Подписка по адресу'**
  String get addUrlTitle;

  /// No description provided for @addUrlSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Обновляется сама по интервалу провайдера'**
  String get addUrlSubtitle;

  /// No description provided for @addFileTitle.
  ///
  /// In ru, this message translates to:
  /// **'Файл config.json'**
  String get addFileTitle;

  /// No description provided for @addFileSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Для опытных: полный конфиг ядра'**
  String get addFileSubtitle;

  /// No description provided for @addLinkHint.
  ///
  /// In ru, this message translates to:
  /// **'vless://… или несколько строк, или подписка в base64'**
  String get addLinkHint;

  /// No description provided for @addUrlHint.
  ///
  /// In ru, this message translates to:
  /// **'https://провайдер.example/подписка'**
  String get addUrlHint;

  /// No description provided for @settingsTitle.
  ///
  /// In ru, this message translates to:
  /// **'Часть трафика напрямую'**
  String get settingsTitle;

  /// No description provided for @probeTarget.
  ///
  /// In ru, this message translates to:
  /// **'Точка проб'**
  String get probeTarget;

  /// No description provided for @probeTargetSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Адрес, до которого клиент меряет задержку узлов'**
  String get probeTargetSubtitle;

  /// No description provided for @probeApplied.
  ///
  /// In ru, this message translates to:
  /// **'Точка проб сохранена'**
  String get probeApplied;

  /// No description provided for @restartForProbeBody.
  ///
  /// In ru, this message translates to:
  /// **'Новая точка проб работает в поднятом заново подключении. Открытые соединения прервутся.'**
  String get restartForProbeBody;

  /// No description provided for @presetOff.
  ///
  /// In ru, this message translates to:
  /// **'Выключено'**
  String get presetOff;

  /// No description provided for @presetRu.
  ///
  /// In ru, this message translates to:
  /// **'Россия напрямую'**
  String get presetRu;

  /// No description provided for @presetOffSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Весь трафик идёт через подключение'**
  String get presetOffSubtitle;

  /// No description provided for @presetOnSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Сайты пресета открываются мимо подключения'**
  String get presetOnSubtitle;

  /// No description provided for @myRules.
  ///
  /// In ru, this message translates to:
  /// **'Мои правила'**
  String get myRules;

  /// No description provided for @myRulesEmpty.
  ///
  /// In ru, this message translates to:
  /// **'Правил пока нет'**
  String get myRulesEmpty;

  /// No description provided for @myRulesCount.
  ///
  /// In ru, this message translates to:
  /// **'Правил: {count}'**
  String myRulesCount(int count);

  /// No description provided for @presetSelected.
  ///
  /// In ru, this message translates to:
  /// **'Пресет «{name}» выбран'**
  String presetSelected(String name);

  /// No description provided for @presetApplied.
  ///
  /// In ru, this message translates to:
  /// **'Пресет «{name}» применён'**
  String presetApplied(String name);

  /// No description provided for @subscriptionUpdated.
  ///
  /// In ru, this message translates to:
  /// **'Подписка обновлена'**
  String get subscriptionUpdated;

  /// No description provided for @fileAdded.
  ///
  /// In ru, this message translates to:
  /// **'Файл добавлен'**
  String get fileAdded;

  /// No description provided for @connectionAdded.
  ///
  /// In ru, this message translates to:
  /// **'Подключение добавлено'**
  String get connectionAdded;

  /// No description provided for @subscriptionAdded.
  ///
  /// In ru, this message translates to:
  /// **'Подписка добавлена'**
  String get subscriptionAdded;

  /// No description provided for @profileUntitled.
  ///
  /// In ru, this message translates to:
  /// **'Без названия'**
  String get profileUntitled;

  /// No description provided for @menuRename.
  ///
  /// In ru, this message translates to:
  /// **'Переименовать'**
  String get menuRename;

  /// No description provided for @menuDelete.
  ///
  /// In ru, this message translates to:
  /// **'Удалить'**
  String get menuDelete;

  /// No description provided for @profileCountOne.
  ///
  /// In ru, this message translates to:
  /// **'Один профиль'**
  String get profileCountOne;

  /// No description provided for @profileCountMany.
  ///
  /// In ru, this message translates to:
  /// **'{count} профилей'**
  String profileCountMany(int count);

  /// No description provided for @regionProfileCount.
  ///
  /// In ru, this message translates to:
  /// **'Профилей: {count}'**
  String regionProfileCount(int count);

  /// No description provided for @subscriptionOne.
  ///
  /// In ru, this message translates to:
  /// **'Подписка · один профиль'**
  String get subscriptionOne;

  /// No description provided for @subscriptionMany.
  ///
  /// In ru, this message translates to:
  /// **'Подписка · {count} профилей'**
  String subscriptionMany(int count);

  /// No description provided for @subscriptionLeftMb.
  ///
  /// In ru, this message translates to:
  /// **'Подписка · осталось {mb} МБ'**
  String subscriptionLeftMb(String mb);

  /// No description provided for @regionTitle.
  ///
  /// In ru, this message translates to:
  /// **'Страна выхода'**
  String get regionTitle;

  /// No description provided for @statusProtected.
  ///
  /// In ru, this message translates to:
  /// **'Защищено'**
  String get statusProtected;

  /// No description provided for @statusConnecting.
  ///
  /// In ru, this message translates to:
  /// **'Подключение…'**
  String get statusConnecting;

  /// No description provided for @statusFailed.
  ///
  /// In ru, this message translates to:
  /// **'Сбой'**
  String get statusFailed;

  /// No description provided for @statusNoLink.
  ///
  /// In ru, this message translates to:
  /// **'Нет связи'**
  String get statusNoLink;

  /// No description provided for @statusOff.
  ///
  /// In ru, this message translates to:
  /// **'Отключено'**
  String get statusOff;

  /// No description provided for @orbDisconnect.
  ///
  /// In ru, this message translates to:
  /// **'Отключить'**
  String get orbDisconnect;

  /// No description provided for @orbConnect.
  ///
  /// In ru, this message translates to:
  /// **'Подключить'**
  String get orbConnect;

  /// No description provided for @orbRetry.
  ///
  /// In ru, this message translates to:
  /// **'Подключить снова'**
  String get orbRetry;

  /// No description provided for @emptyTitle.
  ///
  /// In ru, this message translates to:
  /// **'Быстрый доступ в интернет'**
  String get emptyTitle;

  /// No description provided for @emptyBody.
  ///
  /// In ru, this message translates to:
  /// **'Добавьте ключ от вашего провайдера или адрес подписки — клиент сам соберёт подключение. Своих серверов у клиента нет, он работает с любым провайдером.'**
  String get emptyBody;

  /// No description provided for @emptyAddButton.
  ///
  /// In ru, this message translates to:
  /// **'Добавить подключение'**
  String get emptyAddButton;

  /// No description provided for @trayShowWindow.
  ///
  /// In ru, this message translates to:
  /// **'Показать окно'**
  String get trayShowWindow;

  /// No description provided for @trayQuit.
  ///
  /// In ru, this message translates to:
  /// **'Выйти'**
  String get trayQuit;

  /// No description provided for @alreadyRunningTitle.
  ///
  /// In ru, this message translates to:
  /// **'Клиент уже запущен'**
  String get alreadyRunningTitle;

  /// No description provided for @alreadyRunningBody.
  ///
  /// In ru, this message translates to:
  /// **'Приложение открыто в другом окне. Второе окно не поднимается: два экземпляра спорят из-за системного прокси, и подключение рвётся.'**
  String get alreadyRunningBody;

  /// No description provided for @alreadyRunningClose.
  ///
  /// In ru, this message translates to:
  /// **'Закрыть это окно'**
  String get alreadyRunningClose;

  /// No description provided for @windowHiddenToTray.
  ///
  /// In ru, this message translates to:
  /// **'Клиент свёрнут в трей: подключение продолжает работать.'**
  String get windowHiddenToTray;

  /// No description provided for @closeWindowSection.
  ///
  /// In ru, this message translates to:
  /// **'При закрытии окна'**
  String get closeWindowSection;

  /// No description provided for @closeWindowChoiceAsk.
  ///
  /// In ru, this message translates to:
  /// **'Спрашивать'**
  String get closeWindowChoiceAsk;

  /// No description provided for @closeWindowChoiceTray.
  ///
  /// In ru, this message translates to:
  /// **'Сворачивать в трей'**
  String get closeWindowChoiceTray;

  /// No description provided for @closeWindowChoiceQuit.
  ///
  /// In ru, this message translates to:
  /// **'Выходить'**
  String get closeWindowChoiceQuit;

  /// No description provided for @closeWindowTitle.
  ///
  /// In ru, this message translates to:
  /// **'Закрыть окно?'**
  String get closeWindowTitle;

  /// No description provided for @closeWindowBody.
  ///
  /// In ru, this message translates to:
  /// **'Свернуть в трей — подключение продолжит работать, клиент останется в трее. Выход снимет туннель и закроет приложение.'**
  String get closeWindowBody;

  /// No description provided for @closeWindowTray.
  ///
  /// In ru, this message translates to:
  /// **'Свернуть в трей'**
  String get closeWindowTray;

  /// No description provided for @closeWindowQuit.
  ///
  /// In ru, this message translates to:
  /// **'Выйти'**
  String get closeWindowQuit;

  /// No description provided for @closeWindowRemember.
  ///
  /// In ru, this message translates to:
  /// **'Запомнить выбор'**
  String get closeWindowRemember;

  /// No description provided for @aboutTitle.
  ///
  /// In ru, this message translates to:
  /// **'О программе'**
  String get aboutTitle;

  /// No description provided for @aboutVersion.
  ///
  /// In ru, this message translates to:
  /// **'Версия {version}'**
  String aboutVersion(String version);

  /// No description provided for @aboutRepository.
  ///
  /// In ru, this message translates to:
  /// **'Исходный код и релизы: github.com/lemluik/client-vpn'**
  String get aboutRepository;

  /// No description provided for @aboutLicense.
  ///
  /// In ru, this message translates to:
  /// **'Лицензия'**
  String get aboutLicense;

  /// No description provided for @aboutLicenseSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Mozilla Public License 2.0'**
  String get aboutLicenseSubtitle;

  /// No description provided for @aboutNotices.
  ///
  /// In ru, this message translates to:
  /// **'Уведомления о зависимостях'**
  String get aboutNotices;

  /// No description provided for @aboutNoticesSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Сторонние библиотеки и их лицензии'**
  String get aboutNoticesSubtitle;

  /// No description provided for @aboutNoTelemetry.
  ///
  /// In ru, this message translates to:
  /// **'Сбор статистики'**
  String get aboutNoTelemetry;

  /// No description provided for @aboutNoTelemetryBody.
  ///
  /// In ru, this message translates to:
  /// **'Клиент не собирает статистику и не отправляет данные третьим сторонам: телеметрических и аналитических библиотек в зависимостях нет.'**
  String get aboutNoTelemetryBody;

  /// No description provided for @aboutAssetMissing.
  ///
  /// In ru, this message translates to:
  /// **'Файл не найден в сборке'**
  String get aboutAssetMissing;

  /// No description provided for @updateTitle.
  ///
  /// In ru, this message translates to:
  /// **'Обновление'**
  String get updateTitle;

  /// No description provided for @updateSourceSubtitle.
  ///
  /// In ru, this message translates to:
  /// **'Адрес манифеста релиза. Проверка — один запрос, без идентификатора устройства и профиля'**
  String get updateSourceSubtitle;

  /// No description provided for @updateSourceSaved.
  ///
  /// In ru, this message translates to:
  /// **'Источник обновлений сохранён'**
  String get updateSourceSaved;

  /// No description provided for @updateCheck.
  ///
  /// In ru, this message translates to:
  /// **'Проверить обновление'**
  String get updateCheck;

  /// No description provided for @updateChecking.
  ///
  /// In ru, this message translates to:
  /// **'Проверяю…'**
  String get updateChecking;

  /// No description provided for @updateFound.
  ///
  /// In ru, this message translates to:
  /// **'Доступна версия {version}'**
  String updateFound(String version);

  /// No description provided for @updateOpen.
  ///
  /// In ru, this message translates to:
  /// **'Открыть загрузку'**
  String get updateOpen;

  /// No description provided for @updateCopy.
  ///
  /// In ru, this message translates to:
  /// **'Скопировать ссылку'**
  String get updateCopy;

  /// No description provided for @updateCopied.
  ///
  /// In ru, this message translates to:
  /// **'Ссылка скопирована'**
  String get updateCopied;

  /// No description provided for @updateNoLink.
  ///
  /// In ru, this message translates to:
  /// **'Ссылка на эту платформу в манифесте не указана'**
  String get updateNoLink;

  /// No description provided for @updateOpenFailed.
  ///
  /// In ru, this message translates to:
  /// **'Браузер не открылся — скопируйте ссылку'**
  String get updateOpenFailed;

  /// No description provided for @settingsScreenTitle.
  ///
  /// In ru, this message translates to:
  /// **'Настройки'**
  String get settingsScreenTitle;

  /// No description provided for @settingsThemeSection.
  ///
  /// In ru, this message translates to:
  /// **'Оформление'**
  String get settingsThemeSection;

  /// No description provided for @themeSystem.
  ///
  /// In ru, this message translates to:
  /// **'Системная'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In ru, this message translates to:
  /// **'Светлая'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In ru, this message translates to:
  /// **'Тёмная'**
  String get themeDark;

  /// No description provided for @settingsLaunchSection.
  ///
  /// In ru, this message translates to:
  /// **'Запуск'**
  String get settingsLaunchSection;

  /// No description provided for @settingsAutoStart.
  ///
  /// In ru, this message translates to:
  /// **'Автозапуск с системой'**
  String get settingsAutoStart;

  /// No description provided for @settingsAutoStartAndroid.
  ///
  /// In ru, this message translates to:
  /// **'Клиент откроется сам после включения телефона'**
  String get settingsAutoStartAndroid;

  /// No description provided for @settingsAutoStartDesktop.
  ///
  /// In ru, this message translates to:
  /// **'Клиент откроется сам после входа в систему'**
  String get settingsAutoStartDesktop;

  /// No description provided for @settingsAutoStartOn.
  ///
  /// In ru, this message translates to:
  /// **'Клиент будет запускаться с системой'**
  String get settingsAutoStartOn;

  /// No description provided for @settingsAutoStartOff.
  ///
  /// In ru, this message translates to:
  /// **'Автозапуск выключен'**
  String get settingsAutoStartOff;

  /// No description provided for @settingsAutoConnect.
  ///
  /// In ru, this message translates to:
  /// **'Автоподключение при запуске'**
  String get settingsAutoConnect;

  /// No description provided for @settingsAutoConnectPending.
  ///
  /// In ru, this message translates to:
  /// **'Станет доступно после первого успешного подключения'**
  String get settingsAutoConnectPending;

  /// No description provided for @settingsAutoConnectProfile.
  ///
  /// In ru, this message translates to:
  /// **'Поднимаем то же подключение: {name}'**
  String settingsAutoConnectProfile(String name);

  /// No description provided for @settingsAutoConnectMissing.
  ///
  /// In ru, this message translates to:
  /// **'Подключение больше не найдено'**
  String get settingsAutoConnectMissing;

  /// No description provided for @settingsProfilesSection.
  ///
  /// In ru, this message translates to:
  /// **'Профили ({count})'**
  String settingsProfilesSection(int count);

  /// No description provided for @settingsProfilesEmpty.
  ///
  /// In ru, this message translates to:
  /// **'Подключений пока нет — добавьте их на главном экране.'**
  String get settingsProfilesEmpty;

  /// No description provided for @profileKindLinks.
  ///
  /// In ru, this message translates to:
  /// **'Ссылки'**
  String get profileKindLinks;

  /// No description provided for @profileKindSubscription.
  ///
  /// In ru, this message translates to:
  /// **'Подписка'**
  String get profileKindSubscription;

  /// No description provided for @profileKindFile.
  ///
  /// In ru, this message translates to:
  /// **'Файл config.json'**
  String get profileKindFile;

  /// No description provided for @settingsRoutingSection.
  ///
  /// In ru, this message translates to:
  /// **'Куда идёт трафик'**
  String get settingsRoutingSection;

  /// No description provided for @splitHomeDirect.
  ///
  /// In ru, this message translates to:
  /// **'Сайты домашнего региона напрямую'**
  String get splitHomeDirect;

  /// No description provided for @splitHomeDirectZones.
  ///
  /// In ru, this message translates to:
  /// **'Зоны: {zones}. Остальное — через подключение.'**
  String splitHomeDirectZones(String zones);

  /// No description provided for @splitHomeDirectUnknown.
  ///
  /// In ru, this message translates to:
  /// **'Домашний регион по языку устройства не определён'**
  String get splitHomeDirectUnknown;

  /// No description provided for @splitExceptions.
  ///
  /// In ru, this message translates to:
  /// **'Адреса-исключения'**
  String get splitExceptions;

  /// No description provided for @splitExceptionsCount.
  ///
  /// In ru, this message translates to:
  /// **'напрямую: {direct}, в туннель: {tunnel}'**
  String splitExceptionsCount(int direct, int tunnel);

  /// No description provided for @splitExceptionsEmpty.
  ///
  /// In ru, this message translates to:
  /// **'Списка пока нет'**
  String get splitExceptionsEmpty;

  /// No description provided for @splitScreenTitle.
  ///
  /// In ru, this message translates to:
  /// **'Раздельное туннелирование'**
  String get splitScreenTitle;

  /// No description provided for @splitHowItWorks.
  ///
  /// In ru, this message translates to:
  /// **'Адрес из списка идёт вопреки правилам домашнего региона: «напрямую» мимо туннеля или «в туннель» назло своей зоне. Ссылку можно вставить целиком — из неё возьмём только имя хоста.'**
  String get splitHowItWorks;

  /// No description provided for @splitPasteTitle.
  ///
  /// In ru, this message translates to:
  /// **'Вставить пачкой'**
  String get splitPasteTitle;

  /// No description provided for @splitPasteHint.
  ///
  /// In ru, this message translates to:
  /// **'По одному адресу на строку: https://example.com/path, example.org'**
  String get splitPasteHint;

  /// No description provided for @splitDirection.
  ///
  /// In ru, this message translates to:
  /// **'Куда направить эти адреса'**
  String get splitDirection;

  /// No description provided for @splitToDirect.
  ///
  /// In ru, this message translates to:
  /// **'напрямую'**
  String get splitToDirect;

  /// No description provided for @splitToTunnel.
  ///
  /// In ru, this message translates to:
  /// **'в туннель'**
  String get splitToTunnel;

  /// No description provided for @splitAdded.
  ///
  /// In ru, this message translates to:
  /// **'Добавлено {added}, повторов {duplicates}, пропущено {skipped}'**
  String splitAdded(int added, int duplicates, int skipped);

  /// No description provided for @splitNothingAdded.
  ///
  /// In ru, this message translates to:
  /// **'Ни одного адреса не разобрано, пропущено {skipped}'**
  String splitNothingAdded(int skipped);

  /// No description provided for @splitHostRemoved.
  ///
  /// In ru, this message translates to:
  /// **'Адрес убран из списка'**
  String get splitHostRemoved;

  /// No description provided for @splitHostMoved.
  ///
  /// In ru, this message translates to:
  /// **'Направление изменено'**
  String get splitHostMoved;

  /// No description provided for @splitSaved.
  ///
  /// In ru, this message translates to:
  /// **'Список сохранён'**
  String get splitSaved;

  /// No description provided for @splitApplied.
  ///
  /// In ru, this message translates to:
  /// **'Список применён, подключение поднято заново'**
  String get splitApplied;

  /// No description provided for @splitDirectRuleTitle.
  ///
  /// In ru, this message translates to:
  /// **'Исключения: напрямую'**
  String get splitDirectRuleTitle;

  /// No description provided for @splitTunnelRuleTitle.
  ///
  /// In ru, this message translates to:
  /// **'Исключения: в туннель'**
  String get splitTunnelRuleTitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
