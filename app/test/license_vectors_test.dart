import 'dart:convert';
import 'dart:io';

import 'package:clip_relay/core/license_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/rsa_test_keys.dart';

Map<String, dynamic> m(Object? value) => (value as Map).cast<String, dynamic>();

void main() {
  final publicKey = parseRsaPublicKey(testPublicKeyPem);

  test('stableStringify matches Node for every case', () {
    for (final entry in (licenseVectors['stableStringify'] as List).map(m)) {
      expect(stableStringify(entry['value']), entry['expected']);
    }
  });

  test('valid entitlement signatures verify', () {
    for (final signed in (m(licenseVectors['entitlements'])['valid'] as List).map(m)) {
      expect(() => verifyEntitlement(signed, publicKey), returnsNormally);
    }
  });

  test('tampered entitlements are rejected', () {
    for (final signed in (m(licenseVectors['entitlements'])['mustFail'] as List).map(m)) {
      expect(() => verifyEntitlement(signed, publicKey), throwsA(isA<LicenseException>()), reason: signed['name'] as String);
    }
  });

  test('accepts PEM with escaped newlines from --dart-define', () {
    final escaped = testPublicKeyPem.replaceAll('\n', r'\n');
    expect(parseRsaPublicKey(escaped).modulus, publicKey.modulus);
  });

  test('Node response envelopes decrypt', () async {
    for (final response in (licenseVectors['responses'] as List).map(m)) {
      final payload = await decryptResponseEnvelope(m(response['envelope']), base64Url.decode(base64Url.normalize(response['responseKey'] as String)));
      expect(payload, response['payload']);
    }
  });

  test('tampered or mismatched response envelopes fail', () async {
    for (final response in (licenseVectors['responseMustFail'] as List).map(m)) {
      await expectLater(
        decryptResponseEnvelope(m(response['envelope']), base64Url.decode(base64Url.normalize(response['responseKey'] as String))),
        throwsA(isA<LicenseException>()),
        reason: response['name'] as String,
      );
    }
  });

  test('Node request envelope body opens with the request key', () async {
    final request = m(licenseVectors['request']);
    final body = await openJson(m(request['envelope']), base64Url.decode(base64Url.normalize(request['requestKey'] as String)));
    expect(body, request['payload']);
    expect(rsaOaepDecrypt(base64Url.decode(base64Url.normalize(m(request['envelope'])['key'] as String))),
        base64Url.decode(base64Url.normalize(request['requestKey'] as String)));
  });

  final verifyScript = File('$protocolDir/scripts/verify-license-dart-output.cjs');

  test('Dart request envelope is decrypted by the Node license server', skip: verifyScript.existsSync() ? false : 'requires the license server verify script', () async {
    final payload = {'licenseKey': 'DEV-CLIPBOARD-PRO', 'deviceId': 'm_dart', 'platform': 'ios', 'deviceName': '测试 iPhone', 'requestId': 'r1', 'timestamp': DateTime.now().toUtc().toIso8601String()};
    final encrypted = await encryptRequestPayload(payload, publicKey);
    final dir = await Directory.systemTemp.createTemp('license-dart');
    final file = File('${dir.path}/out.json')
      ..writeAsStringSync(jsonEncode({'privateKeyPem': testPrivateKeyPem, 'envelope': encrypted.envelope, 'expectedPayload': payload}));
    final result = await Process.run('node', [verifyScript.path, file.path]);
    await dir.delete(recursive: true);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final response = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final decrypted = await openJson(response, encrypted.responseKey);
    expect(decrypted, {'echo': payload, 'message': '已收到'});
  });
}
