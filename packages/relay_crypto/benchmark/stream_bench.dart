import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:relay_crypto/relay_crypto.dart';

String mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

Future<void> main(List<String> args) async {
  final total = (args.isNotEmpty ? int.parse(args.first) : 100) * 1024 * 1024;
  final fileKey = generateFileKey();
  final salt = generateSalt();
  const itemId = 'bench-item';
  final chunk = Uint8List.fromList(List.generate(1 << 20, (i) => (i * 31 + 7) & 0xff));

  Stream<List<int>> source() async* {
    for (var remaining = total; remaining > 0; remaining -= chunk.length) {
      yield remaining >= chunk.length ? chunk : Uint8List.sublistView(chunk, 0, remaining);
    }
  }

  final dir = await Directory.systemTemp.createTemp('relay_bench');
  final file = File('${dir.path}/payload.bin');
  final baseRss = ProcessInfo.currentRss;

  final encryptWatch = Stopwatch()..start();
  final sink = file.openWrite();
  await sink.addStream(encryptStream(source(), fileKey: fileKey, salt: salt, itemId: itemId));
  await sink.close();
  encryptWatch.stop();
  final encryptRss = ProcessInfo.maxRss;

  final decryptWatch = Stopwatch()..start();
  var size = 0;
  await for (final part in decryptStream(file.openRead(), fileKey: fileKey, salt: salt, itemId: itemId)) {
    size += part.length;
  }
  decryptWatch.stop();
  final cipherSize = file.lengthSync();
  await dir.delete(recursive: true);

  if (size != total || cipherSize != ciphertextSize(total)) {
    throw StateError('size mismatch: plaintext $size, ciphertext $cipherSize');
  }
  String rate(Stopwatch watch) => (total / (1024 * 1024) / max(watch.elapsedMilliseconds, 1) * 1000).toStringAsFixed(1);
  stdout
    ..writeln('payload: ${mb(total)} MiB (ciphertext ${mb(cipherSize)} MiB)')
    ..writeln('encrypt: ${encryptWatch.elapsedMilliseconds} ms (${rate(encryptWatch)} MiB/s)')
    ..writeln('decrypt: ${decryptWatch.elapsedMilliseconds} ms (${rate(decryptWatch)} MiB/s)')
    ..writeln('rss: start ${mb(baseRss)} MiB, peak after encrypt ${mb(encryptRss)} MiB, peak overall ${mb(ProcessInfo.maxRss)} MiB');
}
