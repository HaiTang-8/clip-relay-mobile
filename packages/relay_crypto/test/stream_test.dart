import 'dart:math';
import 'dart:typed_data';

import 'package:relay_crypto/relay_crypto.dart';
import 'package:test/test.dart';

final Random _random = Random(42);

Uint8List randomData(int length) => Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));

Stream<List<int>> chunked(Uint8List data, List<int> sizes) async* {
  var offset = 0;
  var index = 0;
  while (offset < data.length) {
    final end = min(data.length, offset + sizes[index++ % sizes.length]);
    yield Uint8List.sublistView(data, offset, end);
    offset = end;
  }
}

Future<Uint8List> collect(Stream<List<int>> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

void main() {
  final fileKey = generateFileKey();
  final salt = generateSalt();
  const itemId = 'item-stream';

  test('round trip across frame boundaries with odd chunking', () async {
    for (final length in [0, 1, frameSize - 1, frameSize, frameSize + 1, 3 * frameSize + 17]) {
      final plaintext = randomData(length);
      final ciphertext =
          await collect(encryptStream(chunked(plaintext, [1, 7000, 65536, 100003]), fileKey: fileKey, salt: salt, itemId: itemId));
      expect(ciphertext.length, ciphertextSize(length));
      expect(ciphertext, await encryptPayload(plaintext, fileKey: fileKey, salt: salt, itemId: itemId));
      final decrypted = await collect(decryptStream(chunked(ciphertext, [13, 65552, 99999]), fileKey: fileKey, salt: salt, itemId: itemId));
      expect(decrypted, plaintext, reason: 'length $length');
    }
  });

  test('storage blocks decrypt independently', () async {
    final plaintext = randomData(blockFrames * frameSize + 3 * frameSize + 9);
    final ciphertext = await encryptPayload(plaintext, fileKey: fileKey, salt: salt, itemId: itemId);
    final blocks = splitStorageBlocks(ciphertext.length);
    expect(blocks.length, 2);
    final parts = <Uint8List>[];
    for (final block in blocks) {
      parts.add(await collect(decryptStream(
        Stream.value(Uint8List.sublistView(ciphertext, block.offset, block.offset + block.size)),
        fileKey: fileKey,
        salt: salt,
        itemId: itemId,
        firstFrame: block.firstFrame,
        last: block.last,
      )));
    }
    expect(concatBytes(parts), plaintext);
    await expectLater(
      collect(decryptStream(Stream.value(Uint8List.sublistView(ciphertext, 0, blockSize)), fileKey: fileKey, salt: salt, itemId: itemId)),
      throwsA(isA<RelayCryptoException>()),
    );
    await expectLater(
      collect(decryptStream(
        Stream.value(Uint8List.sublistView(ciphertext, 0, blockSize - frameCiphertextSize)),
        fileKey: fileKey,
        salt: salt,
        itemId: itemId,
        last: false,
      )),
      throwsA(isA<RelayCryptoException>()),
    );
  });

  test('malformed inputs raise RelayCryptoException', () async {
    for (final value in ['AB', 'AAB', 'A', 'AA==', 'A+/A']) {
      expect(() => base64UrlDecodeNoPad(value), throwsA(isA<RelayCryptoException>()), reason: value);
    }
    final keys = await generateDeviceKeys();
    expect(await verifyBindProof('AB', generateFileKey(), keys.x25519PublicKey, keys.ed25519PublicKey), isFalse);
    for (final (method, path) in [('POST\n/x', '/relay/items'), ('POST', '/relay/items\n'), ('GET', '/a b')]) {
      await expectLater(
        signRequest(method: method, path: path, ed25519PrivateKey: keys.ed25519PrivateKey),
        throwsA(isA<RelayCryptoException>()),
      );
    }
  });

  test('wrong recipient and tampered header are rejected', () async {
    final a = await generateDeviceKeys();
    final c = await generateDeviceKeys();
    final stanza = await wrapKey(fileKey, deviceId: 'a', recipientPublicKey: a.x25519PublicKey);
    expect(await unwrapKey(stanza, a.x25519PrivateKey), fileKey);
    await expectLater(unwrapKey(stanza, c.x25519PrivateKey), throwsA(isA<RelayCryptoException>()));

    final header = <String, Object?>{
      'v': 1,
      'itemId': itemId,
      'senderDeviceId': 'a',
      'salt': base64UrlEncodeNoPad(salt),
      'frameSize': frameSize,
      'plaintextSize': 0,
      'recipients': [stanza.toJson()],
      'encManifest': 'x',
    };
    final signature = await signHeader(header, a.ed25519PrivateKey);
    await verifyHeader(header, signature, a.ed25519PublicKey);
    await expectLater(verifyHeader({...header, 'plaintextSize': 1}, signature, a.ed25519PublicKey), throwsA(isA<RelayCryptoException>()));
    await expectLater(verifyHeader(header, signature, c.ed25519PublicKey), throwsA(isA<RelayCryptoException>()));
  });

  test('bind URI round trip with special characters', () async {
    final pc = await generateDeviceKeys();
    final value = BindUri(
      server: "https://relay.example.com/a b?x=1&y=+!*'()",
      bindToken: 'tok/+=',
      deviceId: 'pc 1',
      fingerprint: pc.fingerprintHex,
      pairingSecret: base64UrlEncodeNoPad(generateFileKey()),
    );
    expect(parseBindUri(buildBindUri(value)).toJson(), value.toJson());
  });
}
