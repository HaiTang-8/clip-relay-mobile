import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_relay/core/license_crypto.dart';
import 'package:pointycastle/export.dart' as pc;

final String repoRoot = Directory.current.parent.path;
final String vectorsPath = '$repoRoot/relay-protocol/test-vectors/license-transport-v1.json';

final Map<String, dynamic> licenseVectors = jsonDecode(File(vectorsPath).readAsStringSync()) as Map<String, dynamic>;
final String testPublicKeyPem = (licenseVectors['rsa'] as Map)['publicKeyPem'] as String;
final String testPrivateKeyPem = (licenseVectors['rsa'] as Map)['privateKeyPem'] as String;

pc.RSAPrivateKey parsePkcs8PrivateKey(String pem) {
  final outer = derChildren(derChildren(pemBody(pem)).single.$2);
  final rsa = derChildren(derChildren(outer[2].$2).single.$2);
  return pc.RSAPrivateKey(derInteger(rsa[1].$2), derInteger(rsa[3].$2), derInteger(rsa[4].$2), derInteger(rsa[5].$2));
}

final pc.RSAPrivateKey testPrivateKey = parsePkcs8PrivateKey(testPrivateKeyPem);

String rsaSignBase64Url(List<int> message) {
  final signer = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
    ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(testPrivateKey));
  return base64Url.encode(signer.generateSignature(Uint8List.fromList(message)).bytes).replaceAll('=', '');
}

Uint8List rsaOaepDecrypt(Uint8List data) {
  final cipher = pc.OAEPEncoding.withSHA256(pc.RSAEngine())..init(false, pc.PrivateKeyParameter<pc.RSAPrivateKey>(testPrivateKey));
  return cipher.process(data);
}

Map<String, dynamic> signEntitlement(Map<String, dynamic> entitlement) =>
    {'entitlement': entitlement, 'signature': rsaSignBase64Url(utf8.encode(stableStringify(entitlement))), 'algorithm': 'rsa-sha256'};
