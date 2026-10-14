import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'constants.dart';
import 'encoding.dart';
import 'primitives.dart';

const String _bindUriPrefix = 'cliprelay://bind?';
const int _requestNonceBytes = 16;
final RegExp _timestampPattern = RegExp(r'^\d{1,16}$');
final RegExp _noncePattern = RegExp(r'^[A-Za-z0-9_-]{16,128}$');
final RegExp _fingerprintPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _methodPattern = RegExp(r'^[A-Za-z]{1,16}$');
final RegExp _pathPattern = RegExp(r'^/[\x21-\x7e]*$');

Future<String> signHeader(Map<String, Object?> header, List<int> ed25519PrivateKey) async =>
    base64UrlEncodeNoPad(await ed25519Sign(utf8.encode(canonicalJson(header)), ed25519PrivateKey));

Future<void> verifyHeader(Map<String, Object?> header, String signature, List<int> ed25519PublicKey) async {
  if (header['v'] != relayVersion || header['frameSize'] != frameSize) {
    throw RelayCryptoException('Unsupported relay header');
  }
  if (!await ed25519Verify(utf8.encode(canonicalJson(header)), base64UrlDecodeNoPad(signature), ed25519PublicKey)) {
    throw RelayCryptoException('Relay header signature verification failed');
  }
}

Future<String> bindProof(List<int> pairingSecret, List<int> x25519PublicKey, List<int> ed25519PublicKey) async {
  final mac = await Hmac.sha256().calculateMac(
    concatBytes([
      utf8.encode(labelBind),
      checkLength(x25519PublicKey, keyBytes, 'X25519 public key'),
      checkLength(ed25519PublicKey, keyBytes, 'Ed25519 public key'),
    ]),
    secretKey: SecretKeyData(checkLength(pairingSecret, keyBytes, 'pairing secret')),
  );
  return base64UrlEncodeNoPad(mac.bytes);
}

Future<bool> verifyBindProof(String proof, List<int> pairingSecret, List<int> x25519PublicKey, List<int> ed25519PublicKey) async {
  final expected = base64UrlDecodeNoPad(await bindProof(pairingSecret, x25519PublicKey, ed25519PublicKey));
  try {
    return constantTimeEquals(expected, base64UrlDecodeNoPad(proof));
  } on RelayCryptoException {
    return false;
  }
}

class SignedRequest {
  const SignedRequest({required this.timestamp, required this.nonce, required this.signature});

  final String timestamp;
  final String nonce;
  final String signature;

  Map<String, String> toJson() => {'timestamp': timestamp, 'nonce': nonce, 'signature': signature};
}

List<int> _bodyBytes(Object? body) => switch (body) {
      null => const <int>[],
      String value => utf8.encode(value),
      List<int> value => value,
      _ => throw RelayCryptoException('Unsupported relay request body'),
    };

String requestSigningString({
  required String method,
  required String path,
  Object? body,
  required String timestamp,
  required String nonce,
}) {
  if (!_timestampPattern.hasMatch(timestamp)) throw RelayCryptoException('Invalid relay request timestamp');
  if (!_noncePattern.hasMatch(nonce)) throw RelayCryptoException('Invalid relay request nonce');
  if (!_methodPattern.hasMatch(method)) throw RelayCryptoException('Invalid relay request method');
  if (!_pathPattern.hasMatch(path)) throw RelayCryptoException('Invalid relay request path');
  return [method.toUpperCase(), path, hexEncode(sha256Bytes(_bodyBytes(body))), timestamp, nonce].join('\n');
}

Future<SignedRequest> signRequest({
  required String method,
  required String path,
  Object? body,
  required List<int> ed25519PrivateKey,
  String? timestamp,
  String? nonce,
  RandomBytes? random,
}) async {
  final requestTimestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch.toString();
  final requestNonce = nonce ?? base64UrlEncodeNoPad(randomBytesFrom(random, _requestNonceBytes));
  final signingString = requestSigningString(method: method, path: path, body: body, timestamp: requestTimestamp, nonce: requestNonce);
  return SignedRequest(
    timestamp: requestTimestamp,
    nonce: requestNonce,
    signature: base64UrlEncodeNoPad(await ed25519Sign(utf8.encode(signingString), ed25519PrivateKey)),
  );
}

Future<void> verifyRequest({
  required String method,
  required String path,
  Object? body,
  required String timestamp,
  required String nonce,
  required String signature,
  required List<int> ed25519PublicKey,
  int? now,
  Duration maxSkew = requestMaxSkew,
}) async {
  final signingString = requestSigningString(method: method, path: path, body: body, timestamp: timestamp, nonce: nonce);
  final current = now ?? DateTime.now().millisecondsSinceEpoch;
  if ((current - int.parse(timestamp)).abs() > maxSkew.inMilliseconds) {
    throw RelayCryptoException('Relay request timestamp is outside the accepted window');
  }
  if (!await ed25519Verify(utf8.encode(signingString), base64UrlDecodeNoPad(signature), ed25519PublicKey)) {
    throw RelayCryptoException('Relay request signature verification failed');
  }
}

class BindUri {
  const BindUri({
    required this.server,
    required this.bindToken,
    required this.deviceId,
    required this.fingerprint,
    required this.pairingSecret,
  });

  final String server;
  final String bindToken;
  final String deviceId;
  final String fingerprint;
  final String pairingSecret;

  Map<String, String> toJson() => {
        'server': server,
        'bindToken': bindToken,
        'deviceId': deviceId,
        'fingerprint': fingerprint,
        'pairingSecret': pairingSecret,
      };
}

String buildBindUri(BindUri value) {
  checkLength(base64UrlDecodeNoPad(value.pairingSecret), keyBytes, 'pairing secret');
  final params = [
    ('v', '$relayVersion'),
    ('s', value.server),
    ('t', value.bindToken),
    ('d', value.deviceId),
    ('f', value.fingerprint),
    ('p', value.pairingSecret),
  ];
  return _bindUriPrefix + params.map((entry) => '${entry.$1}=${Uri.encodeComponent(entry.$2)}').join('&');
}

BindUri parseBindUri(String uri) {
  if (!uri.startsWith(_bindUriPrefix)) throw RelayCryptoException('Invalid relay bind URI');
  final Map<String, String> params;
  try {
    params = Uri.splitQueryString(uri.substring(_bindUriPrefix.length));
  } on FormatException {
    throw RelayCryptoException('Invalid relay bind URI');
  }
  final server = params['s'] ?? '';
  final bindToken = params['t'] ?? '';
  final deviceId = params['d'] ?? '';
  final fpr = params['f'] ?? '';
  final pairingSecret = params['p'] ?? '';
  if (params['v'] != '$relayVersion' || server.isEmpty || bindToken.isEmpty || deviceId.isEmpty || !_fingerprintPattern.hasMatch(fpr)) {
    throw RelayCryptoException('Invalid relay bind URI');
  }
  checkLength(base64UrlDecodeNoPad(pairingSecret), keyBytes, 'pairing secret');
  return BindUri(server: server, bindToken: bindToken, deviceId: deviceId, fingerprint: fpr, pairingSecret: pairingSecret);
}
