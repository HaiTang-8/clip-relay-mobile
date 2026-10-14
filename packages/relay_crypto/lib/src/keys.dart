import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'constants.dart';
import 'encoding.dart';
import 'primitives.dart';

class DeviceKeys {
  DeviceKeys({
    required this.x25519PrivateKey,
    required this.x25519PublicKey,
    required this.ed25519PrivateKey,
    required this.ed25519PublicKey,
  });

  factory DeviceKeys.fromJson(Map<String, dynamic> json) => DeviceKeys(
        x25519PrivateKey: base64UrlDecodeNoPad(json['x25519PrivateKey'] as String),
        x25519PublicKey: base64UrlDecodeNoPad(json['x25519PublicKey'] as String),
        ed25519PrivateKey: base64UrlDecodeNoPad(json['ed25519PrivateKey'] as String),
        ed25519PublicKey: base64UrlDecodeNoPad(json['ed25519PublicKey'] as String),
      );

  final Uint8List x25519PrivateKey;
  final Uint8List x25519PublicKey;
  final Uint8List ed25519PrivateKey;
  final Uint8List ed25519PublicKey;

  String get fingerprintHex => fingerprint(x25519PublicKey, ed25519PublicKey);

  Map<String, String> toJson() => {
        'x25519PrivateKey': base64UrlEncodeNoPad(x25519PrivateKey),
        'x25519PublicKey': base64UrlEncodeNoPad(x25519PublicKey),
        'ed25519PrivateKey': base64UrlEncodeNoPad(ed25519PrivateKey),
        'ed25519PublicKey': base64UrlEncodeNoPad(ed25519PublicKey),
      };
}

Future<DeviceKeys> generateDeviceKeys({RandomBytes? random}) async {
  final x25519Seed = randomBytesFrom(random, keyBytes);
  final ed25519Seed = randomBytesFrom(random, keyBytes);
  return DeviceKeys(
    x25519PrivateKey: x25519Seed,
    x25519PublicKey: await x25519PublicKeyOf(x25519Seed),
    ed25519PrivateKey: ed25519Seed,
    ed25519PublicKey: await ed25519PublicKeyOf(ed25519Seed),
  );
}

Uint8List generateFileKey({RandomBytes? random}) => randomBytesFrom(random, keyBytes);

Uint8List generateSalt({RandomBytes? random}) => randomBytesFrom(random, saltBytes);

String fingerprint(List<int> x25519PublicKey, List<int> ed25519PublicKey) => hexEncode(sha256Bytes(concatBytes([
      utf8.encode(labelFingerprint),
      checkLength(x25519PublicKey, keyBytes, 'X25519 public key'),
      checkLength(ed25519PublicKey, keyBytes, 'Ed25519 public key'),
    ])).sublist(0, fingerprintBytes));

String formatFingerprint(String hex) {
  final value = hex.toLowerCase();
  return [for (var i = 0; i < value.length; i += 4) value.substring(i, min(i + 4, value.length))].join(' ');
}

class Stanza {
  Stanza({required this.deviceId, required this.ephPub, required this.wrappedKey});

  factory Stanza.fromJson(Map<String, dynamic> json) => Stanza(
        deviceId: json['deviceId'] as String,
        ephPub: base64UrlDecodeNoPad(json['ephPub'] as String),
        wrappedKey: base64UrlDecodeNoPad(json['wrappedKey'] as String),
      );

  final String deviceId;
  final Uint8List ephPub;
  final Uint8List wrappedKey;

  Map<String, String> toJson() => {
        'deviceId': deviceId,
        'ephPub': base64UrlEncodeNoPad(ephPub),
        'wrappedKey': base64UrlEncodeNoPad(wrappedKey),
      };
}

Future<SecretKeyData> _deriveWrapKey(List<int> privateKey, List<int> peerPublic, List<int> ephPub, List<int> recipientPub) async {
  final pair = await x25519Algorithm.newKeyPairFromSeed(privateKey);
  final shared = await (await x25519Algorithm.sharedSecretKey(
    keyPair: pair,
    remotePublicKey: SimplePublicKey(peerPublic, type: KeyPairType.x25519),
  ))
      .extractBytes();
  if (shared.every((byte) => byte == 0)) {
    throw RelayCryptoException('Relay key agreement produced an all-zero secret');
  }
  return hkdfSha256(shared, concatBytes([ephPub, recipientPub]), labelWrap);
}

Future<Stanza> wrapKey(
  List<int> fileKey, {
  required String deviceId,
  required List<int> recipientPublicKey,
  RandomBytes? random,
}) async {
  final key = checkLength(fileKey, keyBytes, 'file key');
  final recipientPub = checkLength(recipientPublicKey, keyBytes, 'X25519 public key');
  final ephPrivate = randomBytesFrom(random, keyBytes);
  final ephPub = await x25519PublicKeyOf(ephPrivate);
  final wrap = await _deriveWrapKey(ephPrivate, recipientPub, ephPub, recipientPub);
  return Stanza(deviceId: deviceId, ephPub: ephPub, wrappedKey: await aesGcmSeal(wrap, zeroNonce, key, const []));
}

Future<Uint8List> unwrapKey(Stanza stanza, List<int> x25519PrivateKey) async {
  final ephPub = checkLength(stanza.ephPub, keyBytes, 'ephemeral public key');
  final wrapped = checkLength(stanza.wrappedKey, keyBytes + tagBytes, 'wrapped key');
  final recipientPub = await x25519PublicKeyOf(x25519PrivateKey);
  final wrap = await _deriveWrapKey(x25519PrivateKey, ephPub, ephPub, recipientPub);
  return aesGcmOpen(wrap, zeroNonce, wrapped, const [], 'Relay key unwrap failed');
}
