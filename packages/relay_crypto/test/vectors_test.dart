import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:relay_crypto/relay_crypto.dart';
import 'package:relay_crypto/src/primitives.dart' show sha256Bytes;
import 'package:test/test.dart';

final Map<String, dynamic> vectors = jsonDecode(
  File(Platform.environment['RELAY_VECTORS'] ?? '${Platform.environment['RELAY_PROTOCOL_DIR'] ?? '../../relay-protocol'}/test-vectors/v1.json').readAsStringSync(),
) as Map<String, dynamic>;

Map<String, dynamic> get devices => vectors['devices'] as Map<String, dynamic>;
Map<String, dynamic> device(String name) => devices[name] as Map<String, dynamic>;
Uint8List b(Object? value) => base64UrlDecodeNoPad(value as String);
String sha256Hex(List<int> data) => hexEncode(sha256Bytes(data));
List<Map<String, dynamic>> list(Object? value) => (value as List).cast<Map<String, dynamic>>();
Map<String, dynamic> get mustFail => vectors['mustFail'] as Map<String, dynamic>;
RandomBytes fixed(List<List<int>> values) {
  final queue = [...values];
  return (length) => queue.removeAt(0).sublist(0, length);
}

Uint8List mutate(Uint8List data, Map<String, dynamic>? mutation) {
  final out = Uint8List.fromList(data);
  if (mutation == null) return out;
  switch (mutation['type']) {
    case 'flipByte':
      out[mutation['offset'] as int] ^= 0x01;
      return out;
    case 'truncate':
      return Uint8List.sublistView(out, 0, mutation['length'] as int);
    case 'append':
      return concatBytes([out, b(mutation['data'])]);
    case 'swapFrames':
      final a = mutation['a'] as int;
      final c = mutation['b'] as int;
      final frameA = out.sublist(a * frameCiphertextSize, (a + 1) * frameCiphertextSize);
      final frameC = out.sublist(c * frameCiphertextSize, (c + 1) * frameCiphertextSize);
      out.setRange(c * frameCiphertextSize, (c + 1) * frameCiphertextSize, frameA);
      out.setRange(a * frameCiphertextSize, (a + 1) * frameCiphertextSize, frameC);
      return out;
  }
  throw StateError('Unknown mutation ${mutation['type']}');
}

void main() {
  test('constants match', () {
    final constants = vectors['constants'] as Map<String, dynamic>;
    expect(constants['frameSize'], frameSize);
    expect(constants['frameCiphertextSize'], frameCiphertextSize);
    expect(constants['blockFrames'], blockFrames);
    expect(constants['blockSize'], blockSize);
    expect(constants['inlineMaxBytes'], inlineMaxBytes);
    expect(constants['requestMaxSkewMs'], requestMaxSkew.inMilliseconds);
  });

  test('device keys and fingerprints', () async {
    for (final entry in devices.values.cast<Map<String, dynamic>>()) {
      final keys = await generateDeviceKeys(random: fixed([b(entry['x25519PrivateKey']), b(entry['ed25519PrivateKey'])]));
      expect(keys.toJson(), {
        for (final key in ['x25519PrivateKey', 'x25519PublicKey', 'ed25519PrivateKey', 'ed25519PublicKey']) key: entry[key],
      });
      expect(keys.fingerprintHex, entry['fingerprint']);
      expect(formatFingerprint(entry['fingerprint'] as String), entry['fingerprintDisplay']);
    }
  });

  test('canonical JSON', () {
    for (final entry in list(vectors['canonicalJson'])) {
      expect(canonicalJson(entry['value']), entry['expected'], reason: entry['name'] as String);
    }
  });

  test('wrap / unwrap', () async {
    for (final entry in list(vectors['wrap'])) {
      final recipient = device(entry['recipient'] as String);
      final stanza = await wrapKey(
        b(entry['fileKey']),
        deviceId: recipient['deviceId'] as String,
        recipientPublicKey: b(recipient['x25519PublicKey']),
        random: fixed([b(entry['ephemeralPrivateKey'])]),
      );
      expect(stanza.toJson(), entry['stanza']);
      final fileKey = await unwrapKey(Stanza.fromJson(entry['stanza'] as Map<String, dynamic>), b(recipient['x25519PrivateKey']));
      expect(base64UrlEncodeNoPad(fileKey), entry['fileKey']);
    }
  });

  test('unwrap must-fail cases', () async {
    for (final entry in list(mustFail['unwrap'])) {
      await expectLater(
        unwrapKey(Stanza.fromJson(entry['stanza'] as Map<String, dynamic>), b(device(entry['recipient'] as String)['x25519PrivateKey'])),
        throwsA(isA<Exception>()),
        reason: entry['name'] as String,
      );
    }
  });

  test('payload encrypt / decrypt', () async {
    for (final entry in list(vectors['payload'])) {
      final ciphertext = b(entry['ciphertext']);
      expect(ciphertext.length, entry['ciphertextSize']);
      expect(ciphertextSize(entry['plaintextLength'] as int), entry['ciphertextSize']);
      final plaintext =
          await decryptPayload(ciphertext, fileKey: b(entry['fileKey']), salt: b(entry['salt']), itemId: entry['itemId'] as String);
      expect(sha256Hex(plaintext), entry['plaintextSha256'], reason: entry['name'] as String);
      final again =
          await encryptPayload(plaintext, fileKey: b(entry['fileKey']), salt: b(entry['salt']), itemId: entry['itemId'] as String);
      expect(sha256Hex(again), entry['ciphertextSha256'], reason: entry['name'] as String);
    }
  });

  test('payload must-fail cases', () async {
    final bases = {for (final entry in list(vectors['payload'])) entry['name']: entry};
    for (final entry in list(mustFail['payload'])) {
      final base = bases[entry['base']]!;
      final ciphertext = mutate(b(entry['ciphertext'] ?? base['ciphertext']), entry['mutation'] as Map<String, dynamic>?);
      await expectLater(
        decryptPayload(
          ciphertext,
          fileKey: b(entry['fileKey'] ?? base['fileKey']),
          salt: b(entry['salt'] ?? base['salt']),
          itemId: (entry['itemId'] ?? base['itemId']) as String,
        ),
        throwsA(isA<RelayCryptoException>()),
        reason: entry['name'] as String,
      );
    }
  });

  test('sizes and storage blocks', () {
    for (final entry in list(vectors['ciphertextSize'])) {
      expect(ciphertextSize(entry['plaintextSize'] as int), entry['ciphertextSize']);
    }
    for (final entry in list(vectors['storageBlocks'])) {
      expect(splitStorageBlocks(entry['ciphertextSize'] as int).map((block) => block.toJson()).toList(), entry['blocks']);
    }
  });

  test('manifest', () async {
    for (final entry in list(vectors['manifest'])) {
      final options = (fileKey: b(entry['fileKey']), salt: b(entry['salt']), itemId: entry['itemId'] as String);
      expect(canonicalJson(entry['manifest']), entry['canonical']);
      final enc = await encryptManifest(
        entry['manifest'] as Map<String, dynamic>,
        fileKey: options.fileKey,
        salt: options.salt,
        itemId: options.itemId,
        random: fixed([b(entry['nonce'])]),
      );
      expect(enc, entry['encManifest']);
      expect(await decryptManifest(enc, fileKey: options.fileKey, salt: options.salt, itemId: options.itemId), entry['manifest']);
    }
    for (final entry in list(mustFail['manifest'])) {
      await expectLater(
        decryptManifest(entry['encManifest'] as String,
            fileKey: b(entry['fileKey']), salt: b(entry['salt']), itemId: entry['itemId'] as String),
        throwsA(isA<RelayCryptoException>()),
        reason: entry['name'] as String,
      );
    }
  });

  test('header signatures', () async {
    for (final entry in list(vectors['header'])) {
      final signer = device(entry['signer'] as String);
      final header = entry['header'] as Map<String, dynamic>;
      expect(canonicalJson(header), entry['canonical']);
      expect(await signHeader(header, b(signer['ed25519PrivateKey'])), entry['signature']);
      await verifyHeader(header, entry['signature'] as String, b(signer['ed25519PublicKey']));
    }
    for (final entry in list(mustFail['header'])) {
      await expectLater(
        verifyHeader(entry['header'] as Map<String, dynamic>, entry['signature'] as String,
            b(device(entry['signer'] as String)['ed25519PublicKey'])),
        throwsA(isA<RelayCryptoException>()),
        reason: entry['name'] as String,
      );
    }
  });

  test('bind proof', () async {
    for (final entry in list(vectors['bindProof'])) {
      final d = device(entry['device'] as String);
      expect(await bindProof(b(entry['pairingSecret']), b(d['x25519PublicKey']), b(d['ed25519PublicKey'])), entry['proof']);
      expect(await verifyBindProof(entry['proof'] as String, b(entry['pairingSecret']), b(d['x25519PublicKey']), b(d['ed25519PublicKey'])),
          isTrue);
    }
    for (final entry in list(mustFail['bindProof'])) {
      final d = device(entry['device'] as String);
      expect(await verifyBindProof(entry['proof'] as String, b(entry['pairingSecret']), b(d['x25519PublicKey']), b(d['ed25519PublicKey'])),
          isFalse,
          reason: entry['name'] as String);
    }
  });

  Future<void> verify(Map<String, dynamic> entry) => verifyRequest(
        method: entry['method'] as String,
        path: entry['path'] as String,
        body: entry['body'],
        timestamp: entry['timestamp'] as String,
        nonce: entry['nonce'] as String,
        signature: entry['signature'] as String,
        ed25519PublicKey: b(device(entry['signer'] as String)['ed25519PublicKey']),
        now: entry['now'] as int,
      );

  test('request signatures', () async {
    for (final entry in list(vectors['request'])) {
      expect(
        requestSigningString(
          method: entry['method'] as String,
          path: entry['path'] as String,
          body: entry['body'],
          timestamp: entry['timestamp'] as String,
          nonce: entry['nonce'] as String,
        ),
        entry['signingString'],
      );
      final signed = await signRequest(
        method: entry['method'] as String,
        path: entry['path'] as String,
        body: utf8.encode(entry['body'] as String),
        timestamp: entry['timestamp'] as String,
        nonce: entry['nonce'] as String,
        ed25519PrivateKey: b(device(entry['signer'] as String)['ed25519PrivateKey']),
      );
      expect(signed.signature, entry['signature']);
      await verify(entry);
    }
    for (final entry in list(mustFail['request'])) {
      await expectLater(verify(entry), throwsA(isA<RelayCryptoException>()), reason: entry['name'] as String);
    }
  });

  test('bind URI', () {
    for (final entry in list(vectors['bindUri'])) {
      final fields = entry['fields'] as Map<String, dynamic>;
      final value = BindUri(
        server: fields['server'] as String,
        bindToken: fields['bindToken'] as String,
        deviceId: fields['deviceId'] as String,
        fingerprint: fields['fingerprint'] as String,
        pairingSecret: fields['pairingSecret'] as String,
      );
      expect(buildBindUri(value), entry['uri']);
      expect(parseBindUri(entry['uri'] as String).toJson(), fields);
    }
    for (final entry in list(mustFail['bindUri'])) {
      expect(() => parseBindUri(entry['uri'] as String), throwsA(isA<RelayCryptoException>()), reason: entry['name'] as String);
    }
  });

  test('end-to-end items from Node', () async {
    for (final item in list(vectors['items'])) {
      final header = item['header'] as Map<String, dynamic>;
      final expected = item['expected'] as Map<String, dynamic>;
      await verifyHeader(header, item['signature'] as String, b(device(item['sender'] as String)['ed25519PublicKey']));
      for (final name in (item['recipients'] as List).cast<String>()) {
        final d = device(name);
        final stanza = list(header['recipients']).firstWhere((entry) => entry['deviceId'] == d['deviceId']);
        final fileKey = await unwrapKey(Stanza.fromJson(stanza), b(d['x25519PrivateKey']));
        expect(base64UrlEncodeNoPad(fileKey), expected['fileKey']);
        final salt = b(header['salt']);
        final itemId = header['itemId'] as String;
        final manifest = await decryptManifest(header['encManifest'] as String, fileKey: fileKey, salt: salt, itemId: itemId);
        expect(manifest, expected['manifest']);
        final plaintext =
            await decryptPayload(b(item['inlineCiphertext'] ?? item['ciphertext']), fileKey: fileKey, salt: salt, itemId: itemId);
        expect(plaintext.length, header['plaintextSize']);
        expect(sha256Hex(plaintext), expected['plaintextSha256']);
        for (final entry in list(manifest['entries'])) {
          final offset = entry['offset'] as int;
          expect(sha256Hex(plaintext.sublist(offset, offset + (entry['size'] as int))), entry['sha256']);
        }
      }
    }
  });
}
