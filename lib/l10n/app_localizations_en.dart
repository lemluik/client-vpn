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
  String get probeTarget => 'Probe target';

  @override
  String get probeTargetSubtitle =>
      'Address the client measures node latency against';

  @override
  String get probeApplied => 'Probe target saved';

  @override
  String get restartForProbeBody =>
      'The new probe target works in a connection raised again. Open connections will drop.';

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
  String get myRules => 'My rules';

  @override
  String get myRulesEmpty => 'No rules yet';

  @override
  String myRulesCount(int count) {
    return 'Rules: $count';
  }

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
  String get statusNoLink => 'No connection';

  @override
  String get statusOff => 'Off';

  @override
  String trafficRate(String up, String down) {
    return '↑ $up/s · ↓ $down/s';
  }

  @override
  String trafficSession(String up, String down) {
    return 'Session: ↑ $up · ↓ $down';
  }

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

  @override
  String get trayShowWindow => 'Show window';

  @override
  String get trayQuit => 'Quit';

  @override
  String get alreadyRunningTitle => 'The client is already running';

  @override
  String get alreadyRunningBody =>
      'The app is open in another window. A second window does not start: two instances would fight over the system proxy and break the connection.';

  @override
  String get alreadyRunningClose => 'Close this window';

  @override
  String get windowHiddenToTray =>
      'The client is in the tray: the connection stays up.';

  @override
  String get closeWindowSection => 'On window close';

  @override
  String get closeWindowChoiceAsk => 'Ask every time';

  @override
  String get closeWindowChoiceTray => 'Minimize to tray';

  @override
  String get closeWindowChoiceQuit => 'Quit';

  @override
  String get closeWindowTitle => 'Close the window?';

  @override
  String get closeWindowBody =>
      'Minimizing keeps the connection up and leaves the client in the tray. Quitting drops the tunnel and closes the app.';

  @override
  String get closeWindowTray => 'Minimize to tray';

  @override
  String get closeWindowQuit => 'Quit';

  @override
  String get closeWindowRemember => 'Remember my choice';

  @override
  String get aboutTitle => 'About';

  @override
  String aboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get aboutRepository =>
      'Source code and releases: github.com/lemluik/client-vpn';

  @override
  String get aboutLicense => 'License';

  @override
  String get aboutLicenseSubtitle => 'Mozilla Public License 2.0';

  @override
  String get aboutNotices => 'Third-party notices';

  @override
  String get aboutNoticesSubtitle => 'Third-party libraries and their licenses';

  @override
  String get aboutNoTelemetry => 'Data collection';

  @override
  String get aboutNoTelemetryBody =>
      'The client collects no statistics and sends no data to third parties: there are no telemetry or analytics libraries in the dependencies.';

  @override
  String get aboutAssetMissing => 'The file is missing from the build';

  @override
  String get updateTitle => 'Update';

  @override
  String get updateSourceSubtitle =>
      'Address of the release manifest. Checking is a single request without any device or profile identifier';

  @override
  String get updateSourceSaved => 'Update source saved';

  @override
  String get updateCheck => 'Check for update';

  @override
  String get updateChecking => 'Checking…';

  @override
  String updateFound(String version) {
    return 'Version $version is available';
  }

  @override
  String get updateOpen => 'Open download';

  @override
  String get updateCopy => 'Copy link';

  @override
  String get updateCopied => 'Link copied';

  @override
  String get updateNoLink => 'The manifest has no link for this platform';

  @override
  String get updateOpenFailed =>
      'The browser did not open — copy the link instead';

  @override
  String get updateCritical => 'Critical update';

  @override
  String get updateNow => 'Update';

  @override
  String get updateLater => 'Later';

  @override
  String get updateDisableAutoCheck => 'Disable auto-check';

  @override
  String get updateDownloading => 'Downloading update…';

  @override
  String get updateInstallFailed => 'Failed to launch installation';

  @override
  String get updateHashMismatch => 'Checksum mismatch';

  @override
  String get updateDownloadFailed => 'Failed to download update';

  @override
  String get updateApplying => 'Preparing installation…';

  @override
  String get updateWillRestart =>
      'The app will close and update itself — the new version opens in a few seconds';

  @override
  String updateApplied(String version) {
    return 'Update installed: version $version';
  }

  @override
  String get updateUnpackFailed =>
      'Could not unpack the update — opening the download link';

  @override
  String get updateNoWriteAccess =>
      'The app folder is read-only — opening the download link';

  @override
  String get settingsUpdateSection => 'Updates';

  @override
  String get settingsAutoUpdate => 'Check automatically';

  @override
  String get settingsAutoUpdateSubtitle => 'Check for new version on startup';

  @override
  String get settingsScreenTitle => 'Settings';

  @override
  String get settingsThemeSection => 'Appearance';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get settingsLaunchSection => 'Startup';

  @override
  String get settingsAutoStart => 'Start with the system';

  @override
  String get settingsAutoStartAndroid =>
      'The app opens by itself after the phone boots';

  @override
  String get settingsAutoStartDesktop =>
      'The app opens by itself after you sign in';

  @override
  String get settingsAutoStartOn => 'The app will start with the system';

  @override
  String get settingsAutoStartOff => 'Auto-start is off';

  @override
  String get settingsAutoConnect => 'Auto-connect on launch';

  @override
  String get settingsAutoConnectPending =>
      'Becomes available after the first successful connection';

  @override
  String settingsAutoConnectProfile(String name) {
    return 'Bringing up the same connection: $name';
  }

  @override
  String get settingsAutoConnectMissing => 'The connection is no longer there';

  @override
  String settingsProfilesSection(int count) {
    return 'Connections ($count)';
  }

  @override
  String get settingsProfilesEmpty =>
      'No connections yet — add them on the main screen.';

  @override
  String get profileKindLinks => 'Links';

  @override
  String get profileKindSubscription => 'Subscription';

  @override
  String get profileKindFile => 'config.json file';

  @override
  String get settingsRoutingSection => 'Where traffic goes';

  @override
  String get settingsServiceSection => 'Maintenance';

  @override
  String get splitHomeDirect => 'Home-region sites go direct';

  @override
  String splitHomeDirectZones(String zones) {
    return 'Zones: $zones. Everything else goes through the connection.';
  }

  @override
  String get splitHomeDirectUnknown =>
      'The device language does not define a home region';

  @override
  String get splitExceptions => 'Address exceptions';

  @override
  String splitExceptionsCount(int direct, int tunnel) {
    return 'direct: $direct, into the tunnel: $tunnel';
  }

  @override
  String get splitExceptionsEmpty => 'No list yet';

  @override
  String get splitScreenTitle => 'Split tunneling';

  @override
  String get splitHowItWorks =>
      'An address from this list overrides the home-region rules: direct bypasses the tunnel, into-the-tunnel pulls its own zone address back. A full link is fine too — only the host name is taken from it.';

  @override
  String get splitPasteTitle => 'Paste a batch';

  @override
  String get splitPasteHint =>
      'One address per line: https://example.com/path, example.org';

  @override
  String get splitDirection => 'Where these addresses go';

  @override
  String get splitToDirect => 'direct';

  @override
  String get splitToTunnel => 'into the tunnel';

  @override
  String splitAdded(int added, int duplicates, int skipped) {
    return 'Added $added, duplicates $duplicates, skipped $skipped';
  }

  @override
  String splitNothingAdded(int skipped) {
    return 'Not a single address parsed, skipped $skipped';
  }

  @override
  String get splitHostRemoved => 'The address is out of the list';

  @override
  String get splitHostMoved => 'The direction changed';

  @override
  String get splitSaved => 'The list is saved';

  @override
  String get splitApplied => 'The list is applied, the connection is back up';

  @override
  String get splitDirectRuleTitle => 'Exceptions: direct';

  @override
  String get splitTunnelRuleTitle => 'Exceptions: into the tunnel';

  @override
  String trialConnectTitle(String serviceName) {
    return 'Connect $serviceName';
  }

  @override
  String get trialConnectSubtitle => 'Free trial key';

  @override
  String get registrationLoginLabel => 'Telegram login';

  @override
  String get registrationLoginHint => '@username';

  @override
  String get registrationTerms => 'I agree to the testing program terms';

  @override
  String get registrationSubmit => 'Connect';

  @override
  String get registrationInfo =>
      'This is a testing program. Keys are issued free of charge until the end of the year. The support team may run surveys to improve the service.';

  @override
  String get registrationNeedConsent => 'You must agree to the program terms';

  @override
  String get registrationBadLogin =>
      'Enter a Telegram login: @username, 5 to 32 characters';

  @override
  String get registrationSuccess => 'Connected! The key is added.';

  @override
  String registrationFailed(String reason) {
    return 'Could not connect: $reason';
  }

  @override
  String get expiredTitle => 'Key expired';

  @override
  String get expiredBody => 'Your temporary key has expired.';

  @override
  String get expiredSupport => 'To renew it, contact the support team';

  @override
  String get expiredOpenSupport => 'Open support';

  @override
  String get expiredProgramNote =>
      'The testing program is valid until 31.10.2026';

  @override
  String get tileTitle => 'Quick settings tile';

  @override
  String get tileSubtitle =>
      'Start and stop the tunnel without opening the app';

  @override
  String get tileFallback =>
      'Open the shade, tap edit and drag the Tunnel tile onto the quick settings panel';

  @override
  String get fragmentHandshakeTitle => 'Handshake fragmentation';

  @override
  String get fragmentHandshakeSubtitle =>
      'For networks with strict filtering: the start of the TLS handshake goes to the core in pieces. Off by default; turn it on after measuring.';

  @override
  String get fragmentSaved => 'Setting saved';

  @override
  String get fragmentApplied => 'Setting applied, the connection is back up';
}
