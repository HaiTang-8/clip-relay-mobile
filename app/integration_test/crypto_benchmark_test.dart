import 'dart:io';
import 'dart:typed_data';

import 'package:clip_relay/core/models.dart';
import 'package:clip_relay/transfer/payload_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:relay_crypto/relay_crypto.dart';

const int mib = 1024 * 1024;

double rate(int bytes, Stopwatch sw) => bytes / mib / (sw.elapsedMicroseconds / 1e6);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object>{};

  tearDownAll(() {
    binding.reportData = report;
    for (final entry in report.entries) {
      // ignore: avoid_print
      print('BENCH ${entry.key}: ${entry.value}');
    }
  });

  testWidgets('platform AES-GCM is byte-compatible with the Dart implementation', (tester) async {
    final platform = Cryptography.instance.aesGcm(secretKeyLength: 32);
    report['aesGcmImplementation'] = platform.runtimeType.toString();
    final dart = DartAesGcm(secretKeyLength: 32);
    final key = SecretKey(List.generate(32, (i) => i));
    final nonce = List.generate(12, (i) => i * 3);
    final data = Uint8List.fromList(List.generate(frameSize, (i) => i & 0xff));
    final a = await platform.encrypt(data, secretKey: key, nonce: nonce, aad: [1, 2, 3]);
    final b = await dart.encrypt(data, secretKey: key, nonce: nonce, aad: [1, 2, 3]);
    expect(a.cipherText, b.cipherText);
    expect(a.mac.bytes, b.mac.bytes);
    expect(await dart.decrypt(a, secretKey: key, aad: [1, 2, 3]), data);

    final keys = await generateDeviceKeys();
    final stanza = await wrapKey(List.filled(32, 7), deviceId: 'd', recipientPublicKey: keys.x25519PublicKey);
    expect(await unwrapKey(stanza, keys.x25519PrivateKey), List.filled(32, 7));
    final signed = await signRequest(method: 'GET', path: '/relay/devices', body: const <int>[], ed25519PrivateKey: keys.ed25519PrivateKey);
    await verifyRequest(
      method: 'GET',
      path: '/relay/devices',
      body: const <int>[],
      timestamp: signed.timestamp,
      nonce: signed.nonce,
      signature: signed.signature,
      ed25519PublicKey: keys.ed25519PublicKey,
    );
  });

  testWidgets('raw AES-GCM 64 KiB frames, platform vs pure Dart (32 MiB)', (tester) async {
    final key = SecretKey(List.generate(32, (i) => i));
    final frame = Uint8List(frameSize);
    for (final (name, algo) in [('platform', Cryptography.instance.aesGcm(secretKeyLength: 32)), ('dart', DartAesGcm(secretKeyLength: 32))]) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 32 * mib ~/ frameSize; i++) {
        await algo.encrypt(frame, secretKey: key, nonce: List.filled(12, i & 0xff));
      }
      report['rawAesGcm.$name.MiBps'] = rate(32 * mib, sw).toStringAsFixed(1);
    }
  });

  testWidgets('100 MiB file → encrypted 8 MiB block files → decrypted file', (tester) async {
    final dir = await Directory('${(await getTemporaryDirectory()).path}/bench').create(recursive: true);
    final source = File('${dir.path}/source.bin');
    final chunk = Uint8List.fromList(List.generate(mib, (i) => (i * 31 + 7) & 0xff));
    final sink = source.openWrite();
    for (var i = 0; i < 100; i++) {
      sink.add(chunk);
    }
    await sink.close();
    final size = await source.length();
    final fileKey = generateFileKey(), salt = generateSalt();
    const itemId = 'ri_benchmark000000000000';

    var sw = Stopwatch()..start();
    final digest = await sha256Hex(source.openRead());
    report['sha256.MiBps'] = rate(size, sw).toStringAsFixed(1);

    sw = Stopwatch()..start();
    final writer = BlockFileWriter(await Directory('${dir.path}/blocks').create(), blockSize);
    await for (final frame in encryptStream(source.openRead(), fileKey: fileKey, salt: salt, itemId: itemId)) {
      await writer.add(frame);
    }
    await writer.close();
    report['encrypt100MiB.seconds'] = (sw.elapsedMilliseconds / 1000).toStringAsFixed(2);
    report['encrypt.MiBps'] = rate(size, sw).toStringAsFixed(1);
    expect(writer.files, hasLength(13));

    final manifest = Manifest(kind: 'files', entries: [ManifestEntry(name: 'source.bin', mime: 'application/octet-stream', size: size, sha256: digest, offset: 0)]);
    final out = EntrySink(manifest, directory: await Directory('${dir.path}/out').create());
    sw = Stopwatch()..start();
    for (final block in splitStorageBlocks(ciphertextSize(size))) {
      await for (final plain in decryptStream(writer.files[block.index].openRead(),
          fileKey: fileKey, salt: salt, itemId: itemId, firstFrame: block.firstFrame, last: block.last)) {
        await out.add(plain);
      }
    }
    await out.close();
    report['decrypt100MiB.seconds'] = (sw.elapsedMilliseconds / 1000).toStringAsFixed(2);
    report['decrypt.MiBps'] = rate(size, sw).toStringAsFixed(1);
    await dir.delete(recursive: true);
  });
}
