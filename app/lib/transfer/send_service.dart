import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:relay_crypto/relay_crypto.dart';

import '../core/models.dart';
import '../core/relay_api.dart';
import '../core/store.dart';
import 'block_transport.dart';
import 'payload_io.dart';

enum TransferPhase { preparing, encrypting, uploading, committing, downloading, decrypting }

class TransferProgress {
  const TransferProgress(this.phase, this.done, this.total);

  final TransferPhase phase;
  final int done;
  final int total;

  double? get fraction => total > 0 ? (done / total).clamp(0, 1).toDouble() : null;

  String get label => switch (phase) {
        TransferPhase.preparing => '正在准备',
        TransferPhase.encrypting => '正在加密',
        TransferPhase.uploading => '正在上传',
        TransferPhase.committing => '正在提交',
        TransferPhase.downloading => '正在下载',
        TransferPhase.decrypting => '正在解密',
      };
}

typedef ProgressCallback = void Function(TransferProgress progress);
typedef RecipientsProvider = Future<List<RelayDevice>> Function();

class SendDraft {
  const SendDraft({
    required this.kind,
    required this.entries,
    this.preview,
    this.thumbnail,
    this.expiresIn = '24h',
    this.deleteAfterPickup = false,
  });

  final String kind;
  final List<SourceEntry> entries;
  final String? preview;
  final String? thumbnail;
  final String expiresIn;
  final bool deleteAfterPickup;
}

class SendResult {
  const SendResult({required this.itemId, required this.pickupCode, required this.expiresAt});

  final String itemId;
  final String pickupCode;
  final DateTime expiresAt;
}

class OutboxJob {
  OutboxJob({
    required this.itemId,
    required this.pickupCode,
    required this.plaintextSize,
    required this.fileKey,
    required this.salt,
    required this.encManifest,
    required this.summary,
    required this.createdAt,
  });

  factory OutboxJob.fromJson(Map<String, dynamic> json) => OutboxJob(
        itemId: json['itemId'] as String,
        pickupCode: json['pickupCode'] as String,
        plaintextSize: json['plaintextSize'] as int,
        fileKey: base64UrlDecodeNoPad(json['fileKey'] as String),
        salt: base64UrlDecodeNoPad(json['salt'] as String),
        encManifest: json['encManifest'] as String,
        summary: json['summary'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  final String itemId;
  final String pickupCode;
  final int plaintextSize;
  final Uint8List fileKey;
  final Uint8List salt;
  final String encManifest;
  final String summary;
  final DateTime createdAt;

  Map<String, Object> toJson() => {
        'itemId': itemId,
        'pickupCode': pickupCode,
        'plaintextSize': plaintextSize,
        'fileKey': base64UrlEncodeNoPad(fileKey),
        'salt': base64UrlEncodeNoPad(salt),
        'encManifest': encManifest,
        'summary': summary,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };
}

class SendService {
  SendService({
    required this.api,
    required this.me,
    required this.transport,
    required this.workDir,
    required this.store,
    required this.recipients,
    this.retryDelay = const Duration(seconds: 1),
  });

  static const outboxKey = 'relay.outbox';
  static const maxBlockAttempts = 3;

  final RelayApi api;
  final DeviceCredentials me;
  final BlockTransport transport;
  final Directory workDir;
  final KeyValueStore store;
  final RecipientsProvider recipients;
  final Duration retryDelay;

  Directory _jobDir(String itemId) => Directory(p.join(workDir.path, 'outbox', itemId));

  Future<Map<String, OutboxJob>> pendingJobs() async {
    final json = await store.readJson(outboxKey);
    if (json is! Map) return {};
    return json.map((key, value) => MapEntry(key as String, OutboxJob.fromJson((value as Map).cast<String, dynamic>())));
  }

  Future<void> _saveJob(OutboxJob job) async {
    final jobs = await pendingJobs();
    jobs[job.itemId] = job;
    await store.writeJson(outboxKey, jobs.map((key, value) => MapEntry(key, value.toJson())));
  }

  Future<void> _removeJob(String itemId) async {
    final jobs = await pendingJobs();
    if (jobs.remove(itemId) != null) {
      await store.writeJson(outboxKey, jobs.map((key, value) => MapEntry(key, value.toJson())));
    }
    final dir = _jobDir(itemId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> discard(String itemId) async {
    await _removeJob(itemId);
    try {
      await api.deleteItem(itemId);
    } on RelayApiException {
      // Server sweeps abandoned upload sessions after 1h.
    }
  }

  Future<SendResult> send(SendDraft draft, {required ProgressCallback onProgress, required CancelToken cancel}) async {
    final total = draft.entries.fold(0, (sum, entry) => sum + entry.size);
    if (total > maxPlaintextBytes) throw const TransferException('内容超过 100 MB 上限');
    var hashed = 0;
    final entries = <ManifestEntry>[];
    var offset = 0;
    for (final source in draft.entries) {
      cancel.throwIfCancelled();
      final digest = await sha256Hex(source.open(), onBytes: (n) {
        hashed += n;
        onProgress(TransferProgress(TransferPhase.preparing, hashed, total));
      });
      entries.add(ManifestEntry(name: source.name, mime: source.mime, size: source.size, sha256: digest, offset: offset));
      offset += source.size;
    }
    if (offset != total) throw const TransferException('文件在发送过程中被修改，请重试');
    final devices = await recipients();
    cancel.throwIfCancelled();
    final created = await api.createItem(plaintextSize: total, expiresIn: draft.expiresIn, deleteAfterPickup: draft.deleteAfterPickup);
    final fileKey = generateFileKey(), salt = generateSalt();
    final manifest = Manifest(
      kind: draft.kind,
      entries: entries,
      text: draft.preview,
      thumbnail: draft.thumbnail,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    final job = OutboxJob(
      itemId: created.itemId,
      pickupCode: created.pickupCode,
      plaintextSize: total,
      fileKey: fileKey,
      salt: salt,
      encManifest: await encryptManifest(manifest.toJson(), fileKey: fileKey, salt: salt, itemId: created.itemId),
      summary: draft.kind == 'text' ? (draft.preview ?? '文本') : '${entries.length} 个${draft.kind == 'image' ? '图片' : '文件'}',
      createdAt: DateTime.now(),
    );
    var uploaded = false;
    try {
      if (created.inline) {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in concatSources(draft.entries)) {
          builder.add(chunk);
        }
        final ciphertext = await encryptPayload(builder.takeBytes(), fileKey: fileKey, salt: salt, itemId: job.itemId);
        return await _commit(job, devices, onProgress, inlineCiphertext: base64UrlEncodeNoPad(ciphertext), cancel: cancel);
      }
      await _encryptToBlocks(job, draft.entries, created.blocks, onProgress, cancel);
      await _saveJob(job);
      uploaded = true;
      await _upload(job, created.blocks, onProgress, cancel);
      return await _commit(job, devices, onProgress, cancel: cancel);
    } on TransferCancelled {
      await discard(job.itemId);
      rethrow;
    } catch (_) {
      if (!uploaded) await discard(job.itemId);
      rethrow;
    }
  }

  Future<SendResult> resume(OutboxJob job, {required ProgressCallback onProgress, required CancelToken cancel}) async {
    try {
      final blocks = await api.uploadUrls(job.itemId);
      await _upload(job, blocks, onProgress, cancel);
      return await _commit(job, await recipients(), onProgress, cancel: cancel);
    } on RelayApiException catch (error) {
      if (const ['upload_expired', 'item_not_found', 'item_not_uploading'].contains(error.code)) {
        await _removeJob(job.itemId);
        throw TransferException(error.code == 'item_not_uploading' ? '该取件已发送成功' : '上传会话已过期，请重新发送');
      }
      rethrow;
    }
  }

  Future<void> _encryptToBlocks(
    OutboxJob job,
    List<SourceEntry> sources,
    List<TransferUrl> targets,
    ProgressCallback onProgress,
    CancelToken cancel,
  ) async {
    final dir = _jobDir(job.itemId);
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final writer = BlockFileWriter(dir, blockSize);
    final total = ciphertextSize(job.plaintextSize);
    var written = 0;
    try {
      await for (final frame in encryptStream(concatSources(sources), fileKey: job.fileKey, salt: job.salt, itemId: job.itemId)) {
        cancel.throwIfCancelled();
        await writer.add(frame);
        written += frame.length;
        onProgress(TransferProgress(TransferPhase.encrypting, written, total));
      }
    } finally {
      await writer.close();
    }
    if (written != total || writer.files.length != targets.length) {
      throw const TransferException('加密结果与预期大小不一致，文件可能在发送过程中被修改');
    }
    for (final target in targets) {
      if (await writer.files[target.index].length() != target.size) throw const TransferException('加密分块大小异常');
    }
  }

  Future<void> _upload(OutboxJob job, List<TransferUrl> targets, ProgressCallback onProgress, CancelToken cancel) async {
    final dir = _jobDir(job.itemId);
    final total = targets.fold(0, (sum, block) => sum + block.size);
    var base = targets.where((block) => block.uploaded).fold(0, (sum, block) => sum + block.size);
    onProgress(TransferProgress(TransferPhase.uploading, base, total));
    for (var target in targets.where((block) => !block.uploaded)) {
      final file = BlockFileWriter.blockFile(dir, target.index);
      if (!await file.exists() || await file.length() != target.size) {
        await discard(job.itemId);
        throw const TransferException('本地加密缓存已丢失，请重新发送');
      }
      for (var attempt = 1;; attempt++) {
        cancel.throwIfCancelled();
        try {
          final start = base;
          await transport.upload(target, file,
              onProgress: (bytes) => onProgress(TransferProgress(TransferPhase.uploading, start + bytes, total)), cancel: cancel);
          break;
        } on TransferException catch (error) {
          if (attempt >= maxBlockAttempts) rethrow;
          if (error.statusCode == 403) {
            target = (await api.uploadUrls(job.itemId)).firstWhere((block) => block.index == target.index);
          }
          await Future<void>.delayed(retryDelay * attempt);
        }
      }
      base += target.size;
    }
  }

  Future<Map<String, Object?>> _header(OutboxJob job, List<RelayDevice> devices) async => {
        'v': relayVersion,
        'itemId': job.itemId,
        'senderDeviceId': me.deviceId,
        'salt': base64UrlEncodeNoPad(job.salt),
        'frameSize': frameSize,
        'plaintextSize': job.plaintextSize,
        'recipients': [
          for (final device in devices)
            (await wrapKey(job.fileKey, deviceId: device.deviceId, recipientPublicKey: base64UrlDecodeNoPad(device.x25519PublicKey!)))
                .toJson(),
        ],
        'encManifest': job.encManifest,
      };

  Future<SendResult> _commit(
    OutboxJob job,
    List<RelayDevice> devices,
    ProgressCallback onProgress, {
    String? inlineCiphertext,
    required CancelToken cancel,
  }) async {
    for (var attempt = 1;; attempt++) {
      cancel.throwIfCancelled();
      onProgress(const TransferProgress(TransferPhase.committing, 0, 0));
      final header = await _header(job, devices);
      try {
        final item = await api.commit(
          job.itemId,
          header: header,
          signature: await signHeader(header, me.keys.ed25519PrivateKey),
          inlineCiphertext: inlineCiphertext,
        );
        await _removeJob(job.itemId);
        return SendResult(itemId: item.itemId, pickupCode: item.pickupCode, expiresAt: item.expiresAt);
      } on RelayApiException catch (error) {
        if (attempt >= 3) rethrow;
        if (error.code == 'recipients_outdated') {
          devices = await recipients();
        } else if (error.code == 'blocks_incomplete' && inlineCiphertext == null) {
          await _upload(job, await api.uploadUrls(job.itemId), onProgress, cancel);
        } else {
          rethrow;
        }
      }
    }
  }
}
