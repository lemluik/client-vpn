// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'ClientVPN';

  @override
  String get tooltipRefreshSubscription => 'Refresh subscription';

  @override
  String get tooltipAddConnection => 'Add connection';

  @override
  String get tooltipSettings => 'Settings';

  @override
  String get tooltipLog => 'Log';

  @override
  String get tooltipSupport => 'Support';

  @override
  String get tooltipActions => 'Actions';

  @override
  String get buttonCancel => 'Cancel';

  @override
  String get buttonContinue => 'Continue';

  @override
  String get buttonSave => 'Save';

  @override
  String get buttonAdd => 'Add';

  @override
  String get buttonFetch => 'Fetch';

  @override
  String get switchProfileTitle => 'Switch connection?';

  @override
  String get switchProfileBody =>
      'The tunnel will be turned off and raised again from the new profile.';

  @override
  String get switchRegionTitle => 'Change the exit country?';

  @override
  String get switchRegionBody =>
      'The tunnel will be raised again through another country. Open connections will drop.';

  @override
  String get restartForPresetTitle => 'Reconnect?';

  @override
  String get restartForPresetBody =>
      'The new rules work only in a connection raised again. Open connections will drop.';

  @override
  String removeProfileTitle(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get removeProfileBody =>
      'The connection and its cached subscription will be deleted.';

  @override
  String get renameTitle => 'Connection name';

  @override
  String get renameHint => 'For example: work';

  @override
  String get addSheetTitle => 'Add a connection from any provider';

  @override
  String get addLinkTitle => 'Link or subscription';

  @override
  String get addLinkSubtitle => 'Paste a key, a list of keys or a subscription';

  @override
  String get addUrlTitle => 'Subscription by address';

  @override
  String get addUrlSubtitle => 'Refreshes itself on the provider\'s interval';

  @override
  String get addFileTitle => 'config.json file';

  @override
  String get addFileSubtitle => 'For experts: a full kernel config';

  @override
  String get addLinkHint =>
      'vless://… or several lines, or a base64 subscription';

  @override
  String get addUrlHint => 'https://provider.example/subscription';

  @override
  String get settingsTitle => 'Part of the traffic directly';

  @override
  String get presetOff => 'Off';

  @override
  String get presetRu => 'Russia directly';

  @override
  String get presetOffSubtitle => 'All traffic goes through the connection';

  @override
  String get presetOnSubtitle =>
      'The preset\'s sites open bypassing the connection';

  @override
  String presetSelected(String name) {
    return 'Preset “$name” selected';
  }

  @override
  String presetApplied(String name) {
    return 'Preset “$name” applied';
  }

  @override
  String get subscriptionUpdated => 'Subscription updated';

  @override
  String get fileAdded => 'File added';

  @override
  String get connectionAdded => 'Connection added';

  @override
  String get subscriptionAdded => 'Subscription added';

  @override
  String get profileUntitled => 'Untitled';

  @override
  String get menuRename => 'Rename';

  @override
  String get menuDelete => 'Delete';

  @override
  String get profileKindFile => 'Kernel file';

  @override
  String get profileCountOne => 'One profile';

  @override
  String profileCountMany(int count) {
    return '$count profiles';
  }

  @override
  String regionProfileCount(int count) {
    return 'Profiles: $count';
  }

  @override
  String get subscriptionOne => 'Subscription · one profile';

  @override
  String subscriptionMany(int count) {
    return 'Subscription · $count profiles';
  }

  @override
  String subscriptionLeftMb(String mb) {
    return 'Subscription · $mb MB left';
  }

  @override
  String get regionTitle => 'Exit country';

  @override
  String get statusProtected => 'Protected';

  @override
  String get statusConnecting => 'Connecting…';

  @override
  String get statusFailed => 'Failure';

  @override
  String get statusOff => 'Off';

  @override
  String get orbDisconnect => 'Disconnect';

  @override
  String get orbConnect => 'Connect';

  @override
  String get orbRetry => 'Connect again';

  @override
  String get emptyTitle => 'Quick access to the internet';

  @override
  String get emptyBody =>
      'Add a key from your provider or a subscription address — the client builds the connection itself. The client has no servers of its own and works with any provider.';

  @override
  String get emptyAddButton => 'Add connection';
}
