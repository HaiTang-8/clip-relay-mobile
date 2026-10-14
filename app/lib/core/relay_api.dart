import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' show RSAPublicKey;
import 'package:relay_crypto/relay_crypto.dart';

import 'license_crypto.dart';
import 'models.dart';

const _errorMessages = {
  'device_inactive': '此设备已被释放，请重新绑定',
  'subscription_revoked': '订阅已被撤销',
  'subscription_expired': '订阅已过期',
  'clock_skew': '手机系统时间不准确，请校准后重试',
  'device_limit': '订阅设备名额已满，请到电脑端或后台释放设备后重试',
  'bind_token_invalid': '绑定二维码无效，请在电脑端重新生成',
  'bind_token_used': '绑定二维码已被使用，请在电脑端重新生成',
  'bind_token_expired': '绑定二维码已过期，请在电脑端重新生成',
  'device_id_conflict': '设备标识冲突，请重置本机后重新绑定',
  'item_too_large': '内容超过 100 MB 上限',
  'quota_exceeded': '订阅的中转空间（1 GB）已满，请删除旧取件或等待过期',
  'item_not_found': '取件不存在或已被删除',
  'item_expired': '取件已过期',
  'upload_expired': '上传会话已过期，请重新发送',
  'pickup_code_unavailable': '暂时无法分配取件码，请重试',
  'unauthorized': '设备未授权，请重新绑定',
  'invalid_signature': '请求签名无效，请重新绑定',
  'replayed_request': '请求重复，请重试',
  'recipients_outdated': '订阅内设备已变化，请重试',
  'blocks_incomplete': '部分数据块未上传完成，请重试',
  'item_not_uploading': '该取件已提交',
  'not_recipient': '此设备不是该取件的接收者',
  'invalid_header_signature': '取件签名无效',
  'network': '网络连接失败，请检查网络',
};

const _licenseMessages = {
  'License key is not valid': '授权码无效',
  'License key has been revoked': '授权码已被撤销',
  'Subscription has been revoked': '订阅已被撤销',
  'Subscription has expired': '订阅已过期',
  'Device limit reached for this subscription': '订阅设备名额已满，请到电脑端或后台释放设备后重试',
  'Device is not registered for this subscription': '此设备已被释放，请重新绑定',
  'Encrypted request timestamp is outside the accepted window': '手机系统时间不准确，请校准后重试',
};

class RelayApiException implements Exception {
  RelayApiException(this.status, this.code, this.message, [this.details = const {}]);

  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> details;

  String get userMessage => _errorMessages[code] ?? _licenseMessages[message] ?? message;

  @override
  String toString() => userMessage;
}

class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.subscriptionId, required this.ed25519PrivateKey});

  factory DeviceIdentity.of(DeviceCredentials credentials) => DeviceIdentity(
        deviceId: credentials.deviceId,
        subscriptionId: credentials.subscriptionId,
        ed25519PrivateKey: credentials.keys.ed25519PrivateKey,
      );

  final String deviceId;
  final String subscriptionId;
  final List<int> ed25519PrivateKey;
}

class RelayApi {
  RelayApi(this.baseUrl, {http.Client? client, this.identity, this.timeout = const Duration(seconds: 30)}) : _client = client ?? http.Client();

  final Uri baseUrl;
  final DeviceIdentity? identity;
  final Duration timeout;
  final http.Client _client;

  Uri _url(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, dynamic>> _send(http.BaseRequest request, {List<int>? responseKey}) async {
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(timeout));
    } on TimeoutException {
      throw RelayApiException(0, 'network', '连接服务器超时，请检查网络');
    } on http.ClientException catch (error) {
      throw RelayApiException(0, 'network', '无法连接服务器：${error.message}');
    } on IOException catch (error) {
      throw RelayApiException(0, 'network', '无法连接服务器：$error');
    }
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    Object? body;
    try {
      body = response.body.isEmpty ? <String, dynamic>{} : jsonDecode(utf8.decode(response.bodyBytes));
      if (responseKey != null && isTransportEnvelope(body)) {
        body = await decryptResponseEnvelope((body as Map).cast<String, dynamic>(), responseKey);
      } else if (responseKey != null && ok) {
        throw const LicenseException('授权服务器响应未加密，已拒绝');
      }
    } on FormatException {
      body = null;
    }
    final json = body is Map ? body.cast<String, dynamic>() : <String, dynamic>{};
    if (!ok) {
      throw RelayApiException(
        response.statusCode,
        json['code'] as String? ?? 'http_${response.statusCode}',
        json['message'] as String? ?? '服务器返回 HTTP ${response.statusCode}',
        json,
      );
    }
    if (body is! Map) throw RelayApiException(response.statusCode, 'invalid_response', '服务器响应格式无效');
    return json;
  }

  Future<Map<String, dynamic>> signed(String method, String path, [Object? body, DeviceIdentity? as]) async {
    final who = as ?? identity;
    if (who == null) throw StateError('Relay identity is required');
    final raw = utf8.encode(body == null ? '' : jsonEncode(body));
    final signature = await signRequest(method: method, path: path, body: raw, ed25519PrivateKey: who.ed25519PrivateKey);
    final request = http.Request(method, _url(path))
      ..headers.addAll({
        'content-type': 'application/json',
        'x-relay-device': who.deviceId,
        'x-relay-subscription': who.subscriptionId,
        'x-relay-timestamp': signature.timestamp,
        'x-relay-nonce': signature.nonce,
        'x-relay-signature': signature.signature,
      })
      ..bodyBytes = raw;
    return _send(request);
  }

  Future<Map<String, dynamic>> license(String path, Map<String, Object?> payload, RSAPublicKey? transportKey) async {
    final request = http.Request('POST', _url(path))..headers['content-type'] = 'application/json';
    if (transportKey == null) {
      request.body = jsonEncode(payload);
      return _send(request);
    }
    final encrypted = await encryptRequestPayload({
      ...payload,
      'requestId': base64UrlEncodeNoPad(randomBytes(16)),
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    }, transportKey);
    request.body = jsonEncode(encrypted.envelope);
    return _send(request, responseKey: encrypted.responseKey);
  }

  Future<List<RelayDevice>> listDevices() async => [
        for (final device in (await signed('GET', '/relay/devices'))['devices'] as List) RelayDevice.fromJson((device as Map).cast<String, dynamic>()),
      ];

  Future<Map<String, dynamic>> refreshEntitlement() => signed('POST', '/relay/entitlement');

  Future<CreatedItem> createItem({required int plaintextSize, required String expiresIn, required bool deleteAfterPickup}) async =>
      CreatedItem.fromJson(await signed('POST', '/relay/items', {
        'plaintextSize': plaintextSize,
        'expiresIn': expiresIn,
        'deleteAfterPickup': deleteAfterPickup,
      }));

  Future<List<TransferUrl>> uploadUrls(String itemId) async => [
        for (final block in (await signed('GET', '/relay/items/$itemId/upload-urls'))['blocks'] as List)
          TransferUrl.fromJson((block as Map).cast<String, dynamic>()),
      ];

  Future<RelayItem> commit(String itemId, {required Map<String, Object?> header, required String signature, String? inlineCiphertext}) async =>
      RelayItem.fromJson(await signed('POST', '/relay/items/$itemId/commit', {
        'header': header,
        'signature': signature,
        'inlineCiphertext': ?inlineCiphertext,
      }));

  Future<List<RelayItem>> listItems() async => [
        for (final item in (await signed('GET', '/relay/items'))['items'] as List)
          RelayItem.fromJson((item as Map).cast<String, dynamic>()),
      ];

  Future<RelayItem> findByCode(String code) async =>
      RelayItem.fromJson(((await signed('GET', '/relay/items/by-code/${Uri.encodeComponent(code)}'))['item'] as Map).cast<String, dynamic>());

  Future<DownloadInfo> downloadUrls(String itemId) async => DownloadInfo.fromJson(await signed('GET', '/relay/items/$itemId/download-urls'));

  Future<bool> ack(String itemId) async => (await signed('POST', '/relay/items/$itemId/ack'))['deleted'] == true;

  Future<void> deleteItem(String itemId) => signed('DELETE', '/relay/items/$itemId');

  void close() => _client.close();
}
