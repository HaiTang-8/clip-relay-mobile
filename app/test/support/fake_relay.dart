import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_relay/core/license_crypto.dart';
import 'package:clip_relay/core/models.dart';
import 'package:clip_relay/transfer/block_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_crypto/relay_crypto.dart';

import 'rsa_test_keys.dart';

class FakeDevice {
  FakeDevice({required this.deviceId, required this.platform, this.keys, this.name, this.bindProof, this.boundBy});

  final String deviceId;
  final String platform;
  DeviceKeys? keys;
  String? name;
  String? bindProof;
  String? boundBy;
  bool active = true;

  String get kind => platform == 'ios' || platform == 'android' ? 'mobile' : 'desktop';

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'deviceName': name,
        'platform': platform,
        'kind': kind,
        'x25519PublicKey': keys == null ? null : base64UrlEncodeNoPad(keys!.x25519PublicKey),
        'ed25519PublicKey': keys == null ? null : base64UrlEncodeNoPad(keys!.ed25519PublicKey),
        'fingerprint': keys?.fingerprintHex,
        'bindProof': bindProof,
        'boundByDeviceId': boundBy,
        'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
      };
}

class FakeItem {
  FakeItem({required this.id, required this.code, required this.sender, required this.plaintextSize, required this.deleteAfterPickup});

  final String id;
  final String code;
  final String sender;
  final int plaintextSize;
  final bool deleteAfterPickup;
  String status = 'uploading';
  Map<String, dynamic>? header;
  String? signature;
  String? inline;
  DateTime createdAt = DateTime.now().toUtc();
  DateTime? committedAt;

  int get sizeBytes => ciphertextSize(plaintextSize);
  List<StorageBlock> get blocks => sizeBytes <= inlineMaxBytes ? const [] : splitStorageBlocks(sizeBytes);
  List<String> get recipients => [for (final s in (header?['recipients'] as List? ?? const [])) (s as Map)['deviceId'] as String];

  Map<String, Object?> toJson(String viewer) => {
        'itemId': id,
        'pickupCode': code,
        'senderDeviceId': sender,
        'status': status,
        'plaintextSize': plaintextSize,
        'sizeBytes': sizeBytes,
        'blockCount': blocks.length,
        'inline': blocks.isEmpty,
        'deleteAfterPickup': deleteAfterPickup,
        'expiresAt': DateTime.now().toUtc().add(const Duration(hours: 24)).toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'committedAt': committedAt?.toIso8601String(),
        'pickedAt': null,
        'header': header,
        'signature': signature,
        'decryptable': recipients.contains(viewer),
      };
}

class FakeRelay {
  FakeRelay({this.subscriptionId = 'sub_test_000000000000000'});

  final String subscriptionId;
  final Map<String, FakeDevice> devices = {};
  final Map<String, FakeItem> items = {};
  final Map<String, Uint8List> objects = {};
  final Set<String> nonces = {};
  final List<String> log = [];
  final Map<String, String> bindTokens = {};
  int rejectCommits = 0;
  bool plaintextLicenseResponses = false;
  int maxDevices = 5;
  int _seq = 0;

  late final MockClient client = MockClient(_handle);
  http.Client clientFactory() => client;

  Map<String, dynamic> entitlementFor(String deviceId, String platform) => signEntitlement({
        'id': 'e_$deviceId',
        'issuer': 'clipboard-manager-test',
        'licenseKeyHash': 'a' * 64,
        'subscriptionId': subscriptionId,
        'plan': 'pro',
        'period': 'yearly',
        'status': 'active',
        'deviceId': deviceId,
        'deviceLimit': maxDevices,
        'deviceCount': devices.values.where((d) => d.active).length,
        'platform': platform,
        'features': ['sync', 'upload', 'jsonTable', 'advancedBackup', 'relay'],
        'price': {'amount': 169, 'finalAmount': 135.2, 'currency': 'CNY'},
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
        'offlineUntil': DateTime.now().toUtc().add(const Duration(hours: 24)).toIso8601String(),
        'expiresAt': DateTime.now().toUtc().add(const Duration(days: 365)).toIso8601String(),
      });

  http.Response _json(int status, Object body) =>
      http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

  http.Response _error(int status, String code, [Map<String, Object?> extra = const {}]) =>
      _json(status, {'message': code, 'code': code, ...extra});

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    log.add('${request.method} $path');
    if (path == '/mobile/bind' || path == '/activate') return _license(request);
    final device = devices[request.headers['x-relay-device']];
    if (device == null || device.keys == null || request.headers['x-relay-subscription'] != subscriptionId) {
      return _error(401, 'unauthorized');
    }
    final target = request.url.hasQuery ? '$path?${request.url.query}' : path;
    try {
      await verifyRequest(
        method: request.method,
        path: target,
        body: request.bodyBytes,
        timestamp: request.headers['x-relay-timestamp']!,
        nonce: request.headers['x-relay-nonce']!,
        signature: request.headers['x-relay-signature']!,
        ed25519PublicKey: device.keys!.ed25519PublicKey,
      );
    } on RelayCryptoException {
      return _error(401, 'invalid_signature');
    }
    if (!device.active) return _error(403, 'device_inactive');
    if (!nonces.add(request.headers['x-relay-nonce']!)) return _error(401, 'replayed_request');
    final body = request.bodyBytes.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
    final segments = request.url.pathSegments;
    switch ((request.method, segments)) {
      case ('GET', ['relay', 'devices']):
        return _json(200, {'devices': [for (final d in devices.values.where((d) => d.active)) d.toJson()]});
      case ('POST', ['relay', 'entitlement']):
        return _json(200, entitlementFor(device.deviceId, device.platform));
      case ('POST', ['relay', 'items']):
        final size = body['plaintextSize'] as int;
        if (ciphertextSize(size) > ciphertextSize(100 * 1024 * 1024)) return _error(413, 'item_too_large');
        final item = FakeItem(
          id: 'ri_${(_seq++).toString().padLeft(22, '0')}',
          code: (100000 + _seq).toString(),
          sender: device.deviceId,
          plaintextSize: size,
          deleteAfterPickup: body['deleteAfterPickup'] == true,
        );
        items[item.id] = item;
        return _json(200, {...item.toJson(device.deviceId), 'blocks': _uploadUrls(item)});
      case ('GET', ['relay', 'items']):
        return _json(200, {
          'items': [for (final i in items.values.where((i) => i.status == 'ready')) i.toJson(device.deviceId)],
          'serverTime': DateTime.now().toUtc().toIso8601String(),
        });
      case ('GET', ['relay', 'items', 'by-code', final code]):
        final item = items.values.where((i) => i.code == code && i.status == 'ready').firstOrNull;
        return item == null ? _error(404, 'item_not_found') : _json(200, {'item': item.toJson(device.deviceId)});
      case (_, ['relay', 'items', final id, ...]):
        final item = items[id];
        if (item == null || item.status == 'deleted') return _error(404, 'item_not_found');
        return _itemAction(request.method, segments.length > 3 ? segments[3] : '', item, device, body);
    }
    return _error(404, 'not_found');
  }

  List<Map<String, Object?>> _uploadUrls(FakeItem item) => [
        for (final block in item.blocks)
          {
            'index': block.index,
            'size': block.size,
            'url': 'mem://${item.id}/${block.index}',
            'method': 'PUT',
            'headers': <String, String>{},
            'uploaded': objects['${item.id}/${block.index}']?.length == block.size,
          },
      ];

  Future<http.Response> _itemAction(String method, String action, FakeItem item, FakeDevice device, Map<String, dynamic> body) async {
    switch ((method, action)) {
      case ('GET', 'upload-urls'):
        if (item.status != 'uploading') return _error(409, 'item_not_uploading');
        return _json(200, {'itemId': item.id, 'blocks': _uploadUrls(item)});
      case ('POST', 'commit'):
        if (item.status != 'uploading') return _error(409, 'item_not_uploading');
        final header = (body['header'] as Map).cast<String, dynamic>();
        try {
          await verifyHeader(header, body['signature'] as String, device.keys!.ed25519PublicKey);
        } on RelayCryptoException {
          return _error(400, 'invalid_header_signature');
        }
        if (header['itemId'] != item.id || header['plaintextSize'] != item.plaintextSize) return _error(400, 'invalid_header');
        if (item.blocks.isEmpty) {
          final inline = body['inlineCiphertext'] as String?;
          if (inline == null || base64UrlDecodeNoPad(inline).length != item.sizeBytes) return _error(400, 'invalid_inline_ciphertext');
          item.inline = inline;
        } else {
          final missing = [for (final b in item.blocks) if (objects['${item.id}/${b.index}']?.length != b.size) b.index];
          if (missing.isNotEmpty) return _error(409, 'blocks_incomplete', {'blocks': missing});
        }
        final recipients = [for (final s in header['recipients'] as List) (s as Map)['deviceId']];
        if (rejectCommits > 0 || recipients.any((id) => devices[id]?.active != true || devices[id]?.keys == null)) {
          if (rejectCommits > 0) rejectCommits--;
          return _error(409, 'recipients_outdated');
        }
        item
          ..status = 'ready'
          ..header = header
          ..signature = body['signature'] as String
          ..committedAt = DateTime.now().toUtc();
        return _json(200, item.toJson(device.deviceId));
      case ('GET', 'download-urls'):
        if (item.status != 'ready') return _error(404, 'item_not_found');
        if (item.blocks.isEmpty) return _json(200, {'itemId': item.id, 'inline': true, 'inlineCiphertext': item.inline, 'blocks': []});
        return _json(200, {
          'itemId': item.id,
          'inline': false,
          'blocks': [
            for (final b in item.blocks) {'index': b.index, 'size': b.size, 'url': 'mem://${item.id}/${b.index}', 'method': 'GET', 'headers': {}},
          ],
        });
      case ('POST', 'ack'):
        if (!item.recipients.contains(device.deviceId)) return _error(403, 'not_recipient');
        final deleted = item.deleteAfterPickup && item.sender != device.deviceId;
        if (deleted) _delete(item);
        return _json(200, {'itemId': item.id, 'deleted': deleted});
      case ('DELETE', ''):
        _delete(item);
        return _json(200, {'itemId': item.id, 'deleted': true});
    }
    return _error(404, 'not_found');
  }

  void _delete(FakeItem item) {
    item.status = 'deleted';
    objects.removeWhere((key, _) => key.startsWith('${item.id}/'));
  }

  Future<http.Response> _license(http.Request request) async {
    var body = jsonDecode(request.body) as Map<String, dynamic>;
    List<int>? responseKey;
    if (isTransportEnvelope(body)) {
      final requestKey = rsaOaepDecrypt(base64Url.decode(base64Url.normalize(body['key'] as String)));
      responseKey = rsaOaepDecrypt(base64Url.decode(base64Url.normalize(body['responseKey'] as String)));
      body = (await openJson(body, requestKey) as Map).cast<String, dynamic>();
      if (body['requestId'] is! String || body['timestamp'] is! String) return _json(400, {'message': 'bad envelope'});
    }
    Future<http.Response> reply(int status, Map<String, Object?> payload) async {
      if (responseKey == null || plaintextLicenseResponses) return _json(status, payload);
      return _json(status, {'version': 1, 'algorithm': 'rsa-oaep-sha256+aes-256-gcm', ...await sealJson(payload, responseKey)});
    }

    final deviceId = body['deviceId'] as String;
    final keys = DeviceKeys(
      x25519PrivateKey: Uint8List(32),
      x25519PublicKey: base64UrlDecodeNoPad(body['x25519PublicKey'] as String),
      ed25519PrivateKey: Uint8List(32),
      ed25519PublicKey: base64UrlDecodeNoPad(body['ed25519PublicKey'] as String),
    );
    if (devices.values.where((d) => d.active).length >= maxDevices) {
      return reply(403, {'message': 'Device limit reached for this subscription', if (request.url.path == '/mobile/bind') 'code': 'device_limit'});
    }
    if (request.url.path == '/activate') {
      if (body['licenseKey'] != 'DEV-CLIPBOARD-PRO') return reply(403, {'message': 'License key is not valid'});
      devices[deviceId] = FakeDevice(deviceId: deviceId, platform: body['platform'] as String, keys: keys, name: body['deviceName'] as String?);
      return reply(200, entitlementFor(deviceId, body['platform'] as String));
    }
    final issuerId = bindTokens.remove(body['bindToken']);
    if (issuerId == null) return reply(403, {'message': 'Bind token is not valid', 'code': 'bind_token_invalid'});
    devices[deviceId] = FakeDevice(
      deviceId: deviceId,
      platform: body['platform'] as String,
      keys: keys,
      name: body['deviceName'] as String?,
      bindProof: body['bindProof'] as String?,
      boundBy: issuerId,
    );
    return reply(200, {...entitlementFor(deviceId, body['platform'] as String), 'issuerDevice': devices[issuerId]!.toJson()});
  }
}

class MemoryBlockTransport implements BlockTransport {
  MemoryBlockTransport(this.relay);

  final FakeRelay relay;
  final Map<int, int> failUploads = {};
  final List<int> uploaded = [];
  void Function(int index)? onUpload;

  String _key(TransferUrl url) => url.url.substring('mem://'.length);

  @override
  Future<void> upload(TransferUrl target, File file, {required ByteProgress onProgress, required CancelToken cancel}) async {
    cancel.throwIfCancelled();
    onUpload?.call(target.index);
    final failures = failUploads[target.index] ?? 0;
    if (failures > 0) {
      failUploads[target.index] = failures - 1;
      throw const TransferException('上传失败（HTTP 500）', statusCode: 500);
    }
    final bytes = await file.readAsBytes();
    relay.objects[_key(target)] = bytes;
    uploaded.add(target.index);
    onProgress(bytes.length);
  }

  @override
  Future<void> download(TransferUrl source, File file, {required ByteProgress onProgress, required CancelToken cancel}) async {
    cancel.throwIfCancelled();
    final bytes = relay.objects[_key(source)];
    if (bytes == null) throw const TransferException('下载失败（HTTP 404）', statusCode: 404);
    await file.writeAsBytes(bytes);
    onProgress(bytes.length);
  }
}
