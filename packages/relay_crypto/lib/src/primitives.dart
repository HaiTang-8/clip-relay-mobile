import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'constants.dart';
import 'encoding.dart';

final Random _secureRandom = Random.secure();
final X25519 x25519Algorithm = X25519();
final Ed25519 _ed25519 = Ed25519();
final AesGcm _aesGcm = AesGcm.with256bits();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyBytes);
final Uint8List zeroNonce = Uint8List(nonceBytes);

Uint8List randomBytesFrom(RandomBytes? random, int length) {
  final bytes = random != null ? random(length) : List<int>.generate(length, (_) => _secureRandom.nextInt(256));
  if (bytes.length != length) {
    throw RelayCryptoException('Random source returned an unexpected length');
  }
  return Uint8List.fromList(bytes);
}

Uint8List checkLength(List<int> bytes, int length, String name) {
  if (bytes.length != length) {
    throw RelayCryptoException('Invalid $name: expected $length bytes');
  }
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

Uint8List sha256Bytes(List<int> data) => Uint8List.fromList(const DartSha256().hashSync(data).bytes);

Future<SecretKeyData> hkdfSha256(List<int> ikm, List<int> salt, String info) async {
  final key = await _hkdf.deriveKey(secretKey: SecretKeyData(ikm), nonce: salt, info: utf8.encode(info));
  return SecretKeyData(await key.extractBytes());
}

Future<Uint8List> aesGcmSeal(SecretKey key, List<int> nonce, List<int> plaintext, List<int> aad) async {
  final box = await _aesGcm.encrypt(plaintext, secretKey: key, nonce: nonce, aad: aad);
  return concatBytes([box.cipherText, box.mac.bytes]);
}

Future<Uint8List> aesGcmOpen(SecretKey key, List<int> nonce, Uint8List data, List<int> aad, String message) async {
  if (data.length < tagBytes) throw RelayCryptoException(message);
  final split = data.length - tagBytes;
  try {
    final plaintext = await _aesGcm.decrypt(
      SecretBox(Uint8List.sublistView(data, 0, split), nonce: nonce, mac: Mac(Uint8List.sublistView(data, split))),
      secretKey: key,
      aad: aad,
    );
    return plaintext is Uint8List ? plaintext : Uint8List.fromList(plaintext);
  } on SecretBoxAuthenticationError {
    throw RelayCryptoException(message);
  }
}

Future<Uint8List> x25519PublicKeyOf(List<int> privateKey) async {
  final pair = await x25519Algorithm.newKeyPairFromSeed(checkLength(privateKey, keyBytes, 'X25519 private key'));
  return Uint8List.fromList((await pair.extractPublicKey()).bytes);
}

Future<Uint8List> ed25519PublicKeyOf(List<int> privateKey) async {
  final pair = await _ed25519.newKeyPairFromSeed(checkLength(privateKey, keyBytes, 'Ed25519 private key'));
  return Uint8List.fromList((await pair.extractPublicKey()).bytes);
}

Future<Uint8List> ed25519Sign(List<int> message, List<int> privateKey) async {
  final pair = await _ed25519.newKeyPairFromSeed(checkLength(privateKey, keyBytes, 'Ed25519 private key'));
  return Uint8List.fromList((await _ed25519.sign(message, keyPair: pair)).bytes);
}

Future<bool> ed25519Verify(List<int> message, List<int> signature, List<int> publicKey) {
  if (signature.length != 64) return Future.value(false);
  return _ed25519.verify(
    message,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(checkLength(publicKey, keyBytes, 'Ed25519 public key'), type: KeyPairType.ed25519),
    ),
  );
}
