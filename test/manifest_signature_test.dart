import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:client_vpn/manifest_signature.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = ed.newKeyFromSeed(Uint8List.fromList(List<int>.filled(32, 3)));
  final pub = base64.encode(ed.public(key).bytes);
  final otherKey =
      ed.newKeyFromSeed(Uint8List.fromList(List<int>.filled(32, 4)));
  final otherPub = base64.encode(ed.public(otherKey).bytes);
  final message = Uint8List.fromList(utf8.encode('{"version":"0.4.6"}'));
  final signature = ed.sign(key, message);

  test('подпись над точными байтами манифеста принимается', () {
    expect(
      verifyManifestSignature(
        manifestBytes: message,
        signature: signature,
        publicKeyBase64: pub,
      ),
      isTrue,
    );
  });

  test('изменённый манифест, испорченная подпись и чужой ключ — отказ', () {
    final tampered = Uint8List.fromList(message)..[0] ^= 0x01;
    expect(
      verifyManifestSignature(
        manifestBytes: tampered,
        signature: signature,
        publicKeyBase64: pub,
      ),
      isFalse,
    );
    final badSig = Uint8List.fromList(signature)..[63] ^= 0x80;
    expect(
      verifyManifestSignature(
        manifestBytes: message,
        signature: badSig,
        publicKeyBase64: pub,
      ),
      isFalse,
    );
    expect(
      verifyManifestSignature(
        manifestBytes: message,
        signature: signature,
        publicKeyBase64: otherPub,
      ),
      isFalse,
    );
    // Подпись другим ключом над теми же байтами тоже не принимается.
    expect(
      verifyManifestSignature(
        manifestBytes: message,
        signature: ed.sign(otherKey, message),
        publicKeyBase64: pub,
      ),
      isFalse,
    );
  });

  test('неверная длина подписи и ключа, битый base64 — отказ без исключения',
      () {
    for (final sig in [
      <int>[],
      signature.sublist(0, 63),
      [...signature, 0],
    ]) {
      expect(
        verifyManifestSignature(
          manifestBytes: message,
          signature: sig,
          publicKeyBase64: pub,
        ),
        isFalse,
      );
    }
    for (final badKey in ['', 'не base64', base64.encode(List.filled(31, 0))]) {
      expect(
        verifyManifestSignature(
          manifestBytes: message,
          signature: signature,
          publicKeyBase64: badKey,
        ),
        isFalse,
      );
    }
  });

  test('адрес подписи — тот же путь с суффиксом .sig', () {
    expect(
      signatureUrlFor('https://sub.example.test/u/closed/manifest.json'),
      'https://sub.example.test/u/closed/manifest.json.sig',
    );
    expect(
      signatureUrlFor(' http://127.0.0.1:8080/manifest '),
      'http://127.0.0.1:8080/manifest.sig',
    );
  });

  test('подпись openssl принимается клиентом: сервер и клиент совместимы', () {
    // Образец подписан той же командой, что и боевой манифест:
    // openssl pkeyutl -sign -inkey … -rawin -in manifest.json.
    const dir = 'test/fixtures/r92';
    final manifest = File('$dir/manifest.json').readAsBytesSync();
    final sig = File('$dir/manifest.json.sig').readAsBytesSync();
    final pubKey = File('$dir/public_key.txt').readAsStringSync().trim();
    expect(sig.length, ed.SignatureSize);
    expect(base64.decode(pubKey).length, ed.PublicKeySize);
    expect(
      verifyManifestSignature(
        manifestBytes: manifest,
        signature: sig,
        publicKeyBase64: pubKey,
      ),
      isTrue,
    );
    final tampered = Uint8List.fromList(manifest)..[0] ^= 0x20;
    expect(
      verifyManifestSignature(
        manifestBytes: tampered,
        signature: sig,
        publicKeyBase64: pubKey,
      ),
      isFalse,
    );
  });
}