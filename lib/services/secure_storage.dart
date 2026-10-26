import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The secure storage every part of the app uses (device id, chat token).
///
/// On macOS the plugin writes to the data protection keychain by default,
/// which only accepts apps signed with an Apple Developer team id and the
/// `keychain-access-groups` entitlement. The unsigned (ad-hoc) build gets
/// -34018 "A required entitlement is not present" on every write, so the
/// device id and the chat token were never saved. The login keychain works
/// without a team id. Other platforms keep the plugin defaults (Keystore on
/// Android, Credential Manager on Windows).
const FlutterSecureStorage appSecureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
