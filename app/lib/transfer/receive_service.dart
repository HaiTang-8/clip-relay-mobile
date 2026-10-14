import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:relay_crypto/relay_crypto.dart';

import '../core/models.dart';
import '../core/relay_api.dart';
import 'block_transport.dart';
import 'payload_io.dart';
import 'send_service.dart';

class UndecryptableException implements Exception {
  const UndecryptableException();

  @override
  String toString() => '此设备无法解密，请让发送方重新发送';
}

class OpenedItem {
  const OpenedItem({required this.item, required this.manifest, required this.fileKey, required this.salt, required this.plaintextSize});

  final RelayItem item;
  final Manifest manifest;
  final Uint8List fileKey;
  final Uint8List salt;
  final int plaintextSize;
}

class ReceivedContent {
  const ReceivedContent({required this.kind, this.text, this.files = const []});

  final String kind;
  final String? text;
  final List<ReceivedFile> files;
}

typedef SenderKeyLookup = List<int>? Function(String deviceId);

class ReceiveService {
  ReceiveService({required this.api, required this.me, required this.transport, required this.workDir, this.retryDelay = const Duration(seconds: 1)});

  final RelayApi api;
  final DeviceCredentials me;
  final BlockTransport transport;
  final Directory workDir;
  final Duration retryDelay;

  Directory receivedDir(String itemId) => Directory(p.join(workDir.path, 'received', itemId));
  Directory _inboxDir(String itemId) => Directory(p.join(workDir.path, 'inbox', itemId));

  Future<OpenedItem> open(RelayItem item, SenderKeyLookup senderKey) async {
    final header = item.header, signature = item.signature;
    if (header == null || signature == null) throw const TransferException('取件数据不完整');
    final stanzaJson = (header['recipients'] as List? ?? const []).cast<Map>().where((s) => s['deviceId'] == me.deviceId).firstOrNull;
    if (stanzaJson == null) throw const UndecryptableException();
    final key = item.senderDeviceId == me.deviceId ? me.keys.ed25519PublicKey : senderKey(item.senderDeviceId);
    if (key == null) throw const TransferException('无法校验来源：发送设备已不在订阅中或其指纹已变化');
    try {
      await verifyHeader(header, signature, key);
      if (header['itemId'] != item.itemId || header['senderDeviceId'] != item.senderDeviceId) {
        throw RelayCryptoException('Header does not match item');
      }
      final plaintextSize = header['plaintextSize'], salt = header['salt'], encManifest = header['encManifest'];
      final ephPub = stanzaJson['ephPub'], wrappedKey = stanzaJson['wrappedKey'];
      if (plaintextSize is! int || salt is! String || encManifest is! String || ephPub is! String || wrappedKey is! String) {
        throw const FormatException('Invalid header');
      }
      final fileKey = await unwrapKey(
        Stanza(deviceId: me.deviceId, ephPub: base64UrlDecodeNoPad(ephPub), wrappedKey: base64UrlDecodeNoPad(wrappedKey)),
        me.keys.x25519PrivateKey,
      );
      final saltBytes = base64UrlDecodeNoPad(salt);
      final manifest = Manifest.fromJson(
        await decryptManifest(encManifest, fileKey: fileKey, salt: saltBytes, itemId: item.itemId),
      )..validate(plaintextSize);
      return OpenedItem(item: item, manifest: manifest, fileKey: fileKey, salt: saltBytes, plaintextSize: plaintextSize);
    } on RelayCryptoException {
      throw const TransferException('取件校验失败，内容可能被篡改');
    } on FormatException {
      throw const TransferException('取件格式无效');
    }
  }

  Future<ReceivedContent> download(OpenedItem opened, {required ProgressCallback onProgress, required CancelToken cancel}) async {
    final itemId = opened.item.itemId;
    final info = await api.downloadUrls(itemId);
    final totalCiphertext = ciphertextSize(opened.plaintextSize);
    final outDir = receivedDir(itemId);
    if (await outDir.exists()) await outDir.delete(recursive: true);
    if (opened.manifest.kind != 'text') await outDir.create(recursive: true);
    final sink = EntrySink(opened.manifest, directory: outDir);
    try {
      if (info.inline) {
        final ciphertext = base64UrlDecodeNoPad(info.inlineCiphertext ?? '');
        if (ciphertext.length != totalCiphertext) throw const TransferException('取件数据大小异常');
        await for (final chunk in decryptStream(Stream.value(ciphertext), fileKey: opened.fileKey, salt: opened.salt, itemId: itemId)) {
          await sink.add(chunk);
        }
      } else {
        final expected = splitStorageBlocks(totalCiphertext);
        final sources = {for (final block in info.blocks) block.index: block};
        if (sources.length != expected.length || expected.any((block) => sources[block.index]?.size != block.size)) {
          throw const TransferException('取件分块信息异常');
        }
        final files = await _downloadBlocks(itemId, [for (final block in expected) sources[block.index]!], onProgress, cancel);
        var decrypted = 0;
        for (final block in expected) {
          cancel.throwIfCancelled();
          await for (final chunk in decryptStream(
            files[block.index].openRead(),
            fileKey: opened.fileKey,
            salt: opened.salt,
            itemId: itemId,
            firstFrame: block.firstFrame,
            last: block.last,
          )) {
            await sink.add(chunk);
            decrypted += chunk.length;
            onProgress(TransferProgress(TransferPhase.decrypting, decrypted, opened.plaintextSize));
          }
        }
      }
      await sink.close();
    } on RelayCryptoException {
      await sink.discard();
      await clearReceived(itemId);
      throw const TransferException('解密失败，内容可能被篡改');
    } on FormatException catch (error) {
      await sink.discard();
      await clearReceived(itemId);
      throw TransferException(error.message);
    } catch (_) {
      await sink.discard();
      rethrow;
    }
    final inbox = _inboxDir(itemId);
    if (await inbox.exists()) await inbox.delete(recursive: true);
    return opened.manifest.kind == 'text'
        ? ReceivedContent(kind: 'text', text: sink.text)
        : ReceivedContent(kind: opened.manifest.kind, files: sink.files);
  }

  Future<List<File>> _downloadBlocks(String itemId, List<TransferUrl> blocks, ProgressCallback onProgress, CancelToken cancel) async {
    final dir = _inboxDir(itemId);
    await dir.create(recursive: true);
    final total = blocks.fold(0, (sum, block) => sum + block.size);
    var base = 0;
    final files = <File>[];
    for (var block in blocks) {
      final file = File(p.join(dir.path, '${block.index}.blk'));
      files.add(file);
      if (await file.exists() && await file.length() == block.size) {
        base += block.size;
        onProgress(TransferProgress(TransferPhase.downloading, base, total));
        continue;
      }
      for (var attempt = 1;; attempt++) {
        cancel.throwIfCancelled();
        try {
          final start = base;
          await transport.download(block, file,
              onProgress: (bytes) => onProgress(TransferProgress(TransferPhase.downloading, start + bytes, total)), cancel: cancel);
          if (await file.length() != block.size) throw const TransferException('下载的分块大小异常');
          break;
        } on TransferException catch (error) {
          if (await file.exists()) await file.delete();
          if (attempt >= SendService.maxBlockAttempts) rethrow;
          if (error.statusCode == 403) {
            final index = block.index;
            block = (await api.downloadUrls(itemId)).blocks.firstWhere((b) => b.index == index);
          }
          await Future<void>.delayed(retryDelay * attempt);
        }
      }
      base += block.size;
    }
    return files;
  }

  Future<void> clearReceived(String itemId) async {
    for (final dir in [receivedDir(itemId), _inboxDir(itemId)]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}
