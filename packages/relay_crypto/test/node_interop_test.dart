import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:relay_crypto/relay_crypto.dart';
import 'package:relay_crypto/src/primitives.dart' show sha256Bytes;
import 'package:test/test.dart';

final String verifyScript = File('../../relay-protocol/scripts/verify-dart-output.cjs').absolute.path;

Uint8List pattern(int length) => Uint8List.fromList(List.generate(length, (i) => (i * 131 + 3) & 0xff));

Stream<List<int>> chunks(Uint8List data, int size) async* {
  for (var offset = 0; offset < data.length; offset += size) {
    yield Uint8List.sublistView(data, offset, offset + size > data.length ? data.length : offset + size);
  }
}

Future<Map<String, Object?>> buildItem({
  required Directory dir,
  required String itemId,
  required String kind,
  required Uint8List plaintext,
  required DeviceKeys sender,
  required String senderId,
  required Map<String, DeviceKeys> recipients,
}) async {
  final fileKey = generateFileKey();
  final salt = generateSalt();
  final manifest = <String, Object?>{
    'v': 1,
    'kind': kind,
    'entries': [
      {
        'name': kind == 'text' ? '' : '大文件.bin',
        'mime': 'application/octet-stream',
        'size': plaintext.length,
        'sha256': hexEncode(sha256Bytes(plaintext)),
        'offset': 0
      },
    ],
    'createdAt': DateTime.utc(2026, 10, 13).toIso8601String(),
  };
  final header = <String, Object?>{
    'v': 1,
    'itemId': itemId,
    'senderDeviceId': senderId,
    'salt': base64UrlEncodeNoPad(salt),
    'frameSize': frameSize,
    'plaintextSize': plaintext.length,
    'recipients': [
      for (final entry in recipients.entries)
        (await wrapKey(fileKey, deviceId: entry.key, recipientPublicKey: entry.value.x25519PublicKey)).toJson(),
    ],
    'encManifest': await encryptManifest(manifest, fileKey: fileKey, salt: salt, itemId: itemId),
  };
  final result = <String, Object?>{
    'header': header,
    'signature': await signHeader(header, sender.ed25519PrivateKey),
    'expected': {'kind': kind, 'plaintextSha256': hexEncode(sha256Bytes(plaintext))},
  };
  if (ciphertextSize(plaintext.length) <= inlineMaxBytes) {
    result['inlineCiphertext'] = base64UrlEncodeNoPad(await encryptPayload(plaintext, fileKey: fileKey, salt: salt, itemId: itemId));
  } else {
    final file = File('${dir.path}/$itemId.bin');
    final sink = file.openWrite();
    await sink.addStream(encryptStream(chunks(plaintext, 100000), fileKey: fileKey, salt: salt, itemId: itemId));
    await sink.close();
    expect(file.lengthSync(), ciphertextSize(plaintext.length));
    result['ciphertextFile'] = '$itemId.bin';
  }
  return result;
}

void main() {
  test('Node decrypts and verifies Dart output', () async {
    final probe = await Process.run('node', ['--version']).then((r) => r.exitCode == 0).catchError((_) => false);
    if (!probe || !File(verifyScript).existsSync()) {
      markTestSkipped('node or verify script is not available');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('relay_crypto_interop');
    addTearDown(() => dir.delete(recursive: true));

    final sender = await generateDeviceKeys();
    final other = await generateDeviceKeys();
    final recipients = {'dart-sender': sender, 'dart-other': other};
    final items = [
      await buildItem(
        dir: dir,
        itemId: 'dart-text',
        kind: 'text',
        plaintext: Uint8List.fromList(utf8.encode('Dart → Node 你好 📋')),
        sender: sender,
        senderId: 'dart-sender',
        recipients: recipients,
      ),
      await buildItem(
        dir: dir,
        itemId: 'dart-file',
        kind: 'files',
        plaintext: pattern(blockFrames * frameSize + 5000),
        sender: sender,
        senderId: 'dart-sender',
        recipients: recipients,
      ),
    ];

    final requests = <Map<String, Object?>>[];
    for (final (method, path, body) in [
      ('POST', '/relay/items', '{"sizeBytes":1}'),
      ('GET', '/relay/items?since=0', ''),
    ]) {
      final signed = await signRequest(method: method, path: path, body: body, ed25519PrivateKey: sender.ed25519PrivateKey);
      requests.add({'method': method, 'path': path, 'body': body, ...signed.toJson()});
    }

    final pairingSecret = generateFileKey();
    final bind = BindUri(
      server: 'https://relay.example.com/中 继',
      bindToken: 'bt_dart',
      deviceId: 'dart-sender',
      fingerprint: sender.fingerprintHex,
      pairingSecret: base64UrlEncodeNoPad(pairingSecret),
    );
    const canonicalValue = {
      'z': 'a\u0000b\n"\\',
      'emoji': '📋',
      'lone': '\ud800',
      'n': [-1, 0, 9007199254740991],
      'A': null
    };

    final output = {
      'devices': {
        'sender': {
          'x25519PublicKey': base64UrlEncodeNoPad(sender.x25519PublicKey),
          'ed25519PublicKey': base64UrlEncodeNoPad(sender.ed25519PublicKey),
          'fingerprint': sender.fingerprintHex,
        },
        'recipients': [
          for (final entry in recipients.entries)
            {'deviceId': entry.key, 'x25519PrivateKey': base64UrlEncodeNoPad(entry.value.x25519PrivateKey)},
        ],
      },
      'items': items,
      'requests': requests,
      'bind': {
        'proof': await bindProof(pairingSecret, sender.x25519PublicKey, sender.ed25519PublicKey),
        'pairingSecret': base64UrlEncodeNoPad(pairingSecret),
        'uri': buildBindUri(bind),
        'fields': bind.toJson(),
      },
      'canonical': {'value': canonicalValue, 'expected': canonicalJson(canonicalValue)},
    };
    await File('${dir.path}/output.json').writeAsString(jsonEncode(output));

    final result = await Process.run('node', [verifyScript, dir.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('Verified 2 Dart items, 2 requests'));
  });
}
