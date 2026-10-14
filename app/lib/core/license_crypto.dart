import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:relay_crypto/relay_crypto.dart';

const transportVersion = 1;
const transportAlgorithm = 'rsa-oaep-sha256+aes-256-gcm';
const signatureAlgorithm = 'rsa-sha256';

class LicenseException implements Exception {
  const LicenseException(this.message);

  final String message;

  @override
  String toString() => message;
}

List<(int, Uint8List)> derChildren(Uint8List data) {
  final out = <(int, Uint8List)>[];
  var offset = 0;
  while (offset < data.length) {
    final tag = data[offset++];
    var length = data[offset++];
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | data[offset++];
      }
    }
    if (offset + length > data.length) throw const LicenseException('授权公钥格式无效');
    out.add((tag, Uint8List.sublistView(data, offset, offset + length)));
    offset += length;
  }
  return out;
}

BigInt derInteger(Uint8List bytes) => bytes.fold(BigInt.zero, (value, byte) => (value << 8) | BigInt.from(byte));

Uint8List pemBody(String pem) =>
    base64.decode(pem.replaceAll(r'\n', '\n').replaceAll(RegExp(r'-----[A-Z ]+-----'), '').replaceAll(RegExp(r'\s'), ''));

pc.RSAPublicKey parseRsaPublicKey(String pem) {
  try {
    var parts = derChildren(derChildren(pemBody(pem)).single.$2);
    if (parts.length == 2 && parts[1].$1 == 0x03) {
      parts = derChildren(derChildren(Uint8List.sublistView(parts[1].$2, 1)).single.$2);
    }
    return pc.RSAPublicKey(derInteger(parts[0].$2), derInteger(parts[1].$2));
  } catch (_) {
    throw const LicenseException('授权公钥格式无效');
  }
}

String stableStringify(Object? value) {
  if (value is List) return '[${value.map(stableStringify).join(',')}]';
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${canonicalJson(key)}:${stableStringify(value[key])}').join(',')}}';
  }
  if (value is double) {
    if (!value.isFinite) return 'null';
    if (value == value.truncateToDouble() && value.abs() < 1e21) return value.toInt().toString();
    return value.toString();
  }
  if (value is String) return canonicalJson(value);
  return jsonEncode(value);
}

bool _rsaVerify(pc.RSAPublicKey key, List<int> message, Uint8List signature) {
  final signer = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
  try {
    return signer.verifySignature(Uint8List.fromList(message), pc.RSASignature(signature));
  } catch (_) {
    return false;
  }
}

Uint8List _decodeB64(Object? value) {
  final normalized = (value is String ? value : '').replaceAll('-', '+').replaceAll('_', '/');
  return base64.decode(normalized.padRight((normalized.length + 3) ~/ 4 * 4, '='));
}

String _encodeB64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void verifyEntitlement(Map<String, dynamic> signed, pc.RSAPublicKey key) {
  final algorithm = signed['algorithm'] ?? signatureAlgorithm;
  if (algorithm != signatureAlgorithm) throw LicenseException('不支持的授权签名算法：$algorithm');
  final entitlement = signed['entitlement'];
  final Uint8List signature;
  try {
    signature = _decodeB64(signed['signature']);
  } on FormatException {
    throw const LicenseException('授权签名校验失败');
  }
  if (entitlement is! Map || !_rsaVerify(key, utf8.encode(stableStringify(entitlement)), signature)) {
    throw const LicenseException('授权签名校验失败');
  }
}

final AesGcm _aes = AesGcm.with256bits();
final Random _random = Random.secure();

Uint8List randomBytes(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

Future<Map<String, String>> sealJson(Object? payload, List<int> key, {List<int>? iv}) async {
  final nonce = iv ?? randomBytes(12);
  final box = await _aes.encrypt(utf8.encode(jsonEncode(payload)), secretKey: SecretKey(key), nonce: nonce);
  return {'iv': _encodeB64(nonce), 'ciphertext': _encodeB64(box.cipherText), 'tag': _encodeB64(box.mac.bytes)};
}

Future<dynamic> openJson(Map<String, dynamic> envelope, List<int> key) async {
  try {
    final plaintext = await _aes.decrypt(
      SecretBox(_decodeB64(envelope['ciphertext']), nonce: _decodeB64(envelope['iv']), mac: Mac(_decodeB64(envelope['tag']))),
      secretKey: SecretKey(key),
    );
    return jsonDecode(utf8.decode(plaintext));
  } on SecretBoxAuthenticationError {
    throw const LicenseException('授权服务器响应解密失败');
  } on FormatException {
    throw const LicenseException('授权服务器响应格式无效');
  }
}

pc.SecureRandom _secureRandom() => pc.FortunaRandom()..seed(pc.KeyParameter(randomBytes(32)));

Uint8List rsaOaepEncrypt(pc.RSAPublicKey key, List<int> data) {
  final cipher = pc.OAEPEncoding.withSHA256(pc.RSAEngine())
    ..init(true, pc.ParametersWithRandom(pc.PublicKeyParameter<pc.RSAPublicKey>(key), _secureRandom()));
  return cipher.process(Uint8List.fromList(data));
}

bool isTransportEnvelope(Object? value) =>
    value is Map &&
    value['version'] == transportVersion &&
    value['algorithm'] == transportAlgorithm &&
    value['iv'] is String &&
    value['ciphertext'] is String &&
    value['tag'] is String;

class EncryptedRequest {
  const EncryptedRequest(this.envelope, this.responseKey);

  final Map<String, Object?> envelope;
  final Uint8List responseKey;
}

Future<EncryptedRequest> encryptRequestPayload(Map<String, Object?> payload, pc.RSAPublicKey serverKey) async {
  final requestKey = randomBytes(32);
  final responseKey = randomBytes(32);
  return EncryptedRequest({
    'version': transportVersion,
    'algorithm': transportAlgorithm,
    'key': _encodeB64(rsaOaepEncrypt(serverKey, requestKey)),
    'responseKey': _encodeB64(rsaOaepEncrypt(serverKey, responseKey)),
    ...await sealJson(payload, requestKey),
  }, responseKey);
}

Future<dynamic> decryptResponseEnvelope(Map<String, dynamic> envelope, List<int> responseKey) async {
  if (!isTransportEnvelope(envelope)) throw const LicenseException('不支持的授权服务器响应');
  return openJson(envelope, responseKey);
}
