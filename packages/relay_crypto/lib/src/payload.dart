import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'constants.dart';
import 'encoding.dart';
import 'primitives.dart';

class _PayloadKey {
  _PayloadKey(this.key, this.aad);

  final SecretKey key;
  final Uint8List aad;
}

Future<_PayloadKey> _payloadKey(List<int> fileKey, List<int> salt, String itemId) async {
  if (itemId.isEmpty) throw RelayCryptoException('Relay itemId is required');
  final key = await hkdfSha256(
    checkLength(fileKey, keyBytes, 'file key'),
    checkLength(salt, saltBytes, 'salt'),
    labelPayload,
  );
  return _PayloadKey(key, Uint8List.fromList(utf8.encode(itemId)));
}

Uint8List _frameNonce(int counter, bool last) {
  final nonce = Uint8List(nonceBytes);
  var value = counter;
  for (var i = 10; i >= 5; i--) {
    nonce[i] = value & 0xff;
    value >>= 8;
  }
  nonce[nonceBytes - 1] = last ? 1 : 0;
  return nonce;
}

Future<Uint8List> _openFrame(_PayloadKey params, int counter, bool last, Uint8List frame) async {
  final plaintext = await aesGcmOpen(params.key, _frameNonce(counter, last), frame, params.aad, 'Relay payload authentication failed');
  if (last && counter > 0 && plaintext.isEmpty) {
    throw RelayCryptoException('Relay payload has an empty final frame');
  }
  return plaintext;
}

class _ByteQueue {
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _head = 0;
  int length = 0;

  void add(List<int> data) {
    if (data.isEmpty) return;
    _chunks.add(data is Uint8List ? data : Uint8List.fromList(data));
    length += data.length;
  }

  Uint8List take(int count) {
    final out = Uint8List(count);
    var offset = 0;
    while (offset < count) {
      final chunk = _chunks.first;
      final size = min(chunk.length - _head, count - offset);
      out.setRange(offset, offset + size, chunk, _head);
      offset += size;
      _head += size;
      if (_head == chunk.length) {
        _chunks.removeFirst();
        _head = 0;
      }
    }
    length -= count;
    return out;
  }
}

Stream<Uint8List> encryptStream(
  Stream<List<int>> input, {
  required List<int> fileKey,
  required List<int> salt,
  required String itemId,
}) async* {
  final params = await _payloadKey(fileKey, salt, itemId);
  final queue = _ByteQueue();
  var counter = 0;
  await for (final chunk in input) {
    queue.add(chunk);
    while (queue.length > frameSize) {
      yield await aesGcmSeal(params.key, _frameNonce(counter++, false), queue.take(frameSize), params.aad);
    }
  }
  yield await aesGcmSeal(params.key, _frameNonce(counter, true), queue.take(queue.length), params.aad);
}

Stream<Uint8List> decryptStream(
  Stream<List<int>> input, {
  required List<int> fileKey,
  required List<int> salt,
  required String itemId,
  int firstFrame = 0,
  bool last = true,
}) async* {
  final params = await _payloadKey(fileKey, salt, itemId);
  final queue = _ByteQueue();
  final threshold = last ? frameCiphertextSize + 1 : frameCiphertextSize;
  var counter = firstFrame;
  await for (final chunk in input) {
    queue.add(chunk);
    while (queue.length >= threshold) {
      yield await _openFrame(params, counter++, false, queue.take(frameCiphertextSize));
    }
  }
  if (!last) {
    if (queue.length > 0 || counter - firstFrame != blockFrames) throw RelayCryptoException('Relay storage block has an invalid size');
    return;
  }
  if (queue.length < tagBytes) throw RelayCryptoException('Relay payload is truncated');
  yield await _openFrame(params, counter, true, queue.take(queue.length));
}

Future<Uint8List> _collect(Stream<Uint8List> stream) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<Uint8List> encryptPayload(List<int> plaintext, {required List<int> fileKey, required List<int> salt, required String itemId}) =>
    _collect(encryptStream(Stream.value(plaintext), fileKey: fileKey, salt: salt, itemId: itemId));

Future<Uint8List> decryptPayload(List<int> ciphertext, {required List<int> fileKey, required List<int> salt, required String itemId}) =>
    _collect(decryptStream(Stream.value(ciphertext), fileKey: fileKey, salt: salt, itemId: itemId));

int ciphertextSize(int plaintextSize) {
  if (plaintextSize < 0) throw RelayCryptoException('Invalid plaintext size');
  final frames = max(1, (plaintextSize + frameSize - 1) ~/ frameSize);
  return plaintextSize + frames * tagBytes;
}

class StorageBlock {
  const StorageBlock({required this.index, required this.offset, required this.size, required this.firstFrame, required this.last});

  final int index;
  final int offset;
  final int size;
  final int firstFrame;
  final bool last;

  Map<String, Object> toJson() => {'index': index, 'offset': offset, 'size': size, 'firstFrame': firstFrame, 'last': last};
}

List<StorageBlock> splitStorageBlocks(int totalCiphertextSize) {
  if (totalCiphertextSize < tagBytes) throw RelayCryptoException('Invalid ciphertext size');
  final count = (totalCiphertextSize + blockSize - 1) ~/ blockSize;
  return List.generate(
    count,
    (index) => StorageBlock(
      index: index,
      offset: index * blockSize,
      size: min(blockSize, totalCiphertextSize - index * blockSize),
      firstFrame: index * blockFrames,
      last: index == count - 1,
    ),
  );
}

Future<SecretKey> _metaKey(List<int> fileKey, List<int> salt) =>
    hkdfSha256(checkLength(fileKey, keyBytes, 'file key'), checkLength(salt, saltBytes, 'salt'), labelMeta);

Future<String> encryptManifest(
  Map<String, Object?> manifest, {
  required List<int> fileKey,
  required List<int> salt,
  required String itemId,
  RandomBytes? random,
}) async {
  if (itemId.isEmpty) throw RelayCryptoException('Relay itemId is required');
  final nonce = randomBytesFrom(random, nonceBytes);
  final sealed = await aesGcmSeal(await _metaKey(fileKey, salt), nonce, utf8.encode(canonicalJson(manifest)), utf8.encode(itemId));
  return base64UrlEncodeNoPad(concatBytes([nonce, sealed]));
}

Future<Map<String, dynamic>> decryptManifest(
  String encManifest, {
  required List<int> fileKey,
  required List<int> salt,
  required String itemId,
}) async {
  if (itemId.isEmpty) throw RelayCryptoException('Relay itemId is required');
  const message = 'Relay manifest authentication failed';
  final data = base64UrlDecodeNoPad(encManifest);
  if (data.length < nonceBytes + tagBytes) throw RelayCryptoException(message);
  final plaintext = await aesGcmOpen(
    await _metaKey(fileKey, salt),
    Uint8List.sublistView(data, 0, nonceBytes),
    Uint8List.sublistView(data, nonceBytes),
    utf8.encode(itemId),
    message,
  );
  final manifest = jsonDecode(utf8.decode(plaintext));
  if (manifest is! Map<String, dynamic> || manifest['v'] != relayVersion) {
    throw RelayCryptoException('Unsupported relay manifest version');
  }
  return manifest;
}
