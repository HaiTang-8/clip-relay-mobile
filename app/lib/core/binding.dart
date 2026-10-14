import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' show RSAPublicKey;
import 'package:relay_crypto/relay_crypto.dart';

import 'config.dart';
import 'license_crypto.dart';
import 'models.dart';
import 'relay_api.dart';
import 'store.dart';

class BindException implements Exception {
  const BindException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DevicePin {
  const DevicePin({required this.fingerprint, this.verified = false});

  factory DevicePin.fromJson(Map<String, dynamic> json) =>
      DevicePin(fingerprint: json['fingerprint'] as String, verified: json['verified'] as bool? ?? false);

  final String fingerprint;
  final bool verified;

  Map<String, Object> toJson() => {'fingerprint': fingerprint, 'verified': verified};
}

enum TrustState { verified, firstUse, changed, noKeys }

class TrustedDevice {
  const TrustedDevice(this.device, this.trust);

  final RelayDevice device;
  final TrustState trust;

  bool get usable => trust == TrustState.verified || trust == TrustState.firstUse;
}

class BindingService {
  BindingService({
    required this.config,
    required this.store,
    required this.platform,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  static const credentialsKey = 'relay.credentials';
  static const pinsKey = 'relay.pins';

  final AppConfig config;
  final KeyValueStore store;
  final String platform;
  final http.Client Function() _clientFactory;

  RSAPublicKey? get _signingKey => config.publicKey.isEmpty ? null : parseRsaPublicKey(config.publicKey);
  RSAPublicKey? get _transportKey => config.transportPublicKey.isEmpty ? null : parseRsaPublicKey(config.transportPublicKey);

  RelayApi api(Uri server, [DeviceIdentity? identity]) => RelayApi(server, client: _clientFactory(), identity: identity);

  RelayApi apiFor(DeviceCredentials credentials) => api(Uri.parse(credentials.serverUrl), DeviceIdentity.of(credentials));

  Future<DeviceCredentials?> load() async {
    final json = await store.readJson(credentialsKey);
    return json is Map ? DeviceCredentials.fromJson(json.cast<String, dynamic>()) : null;
  }

  Future<Map<String, DevicePin>> loadPins() async {
    final json = await store.readJson(pinsKey);
    if (json is! Map) return {};
    return json.map((key, value) => MapEntry(key as String, DevicePin.fromJson((value as Map).cast<String, dynamic>())));
  }

  Future<void> savePins(Map<String, DevicePin> pins) =>
      store.writeJson(pinsKey, pins.map((key, value) => MapEntry(key, value.toJson())));

  Future<void> reset() async {
    await store.delete(credentialsKey);
    await store.delete(pinsKey);
  }

  Future<List<TrustedDevice>> reconcile(DeviceCredentials me, List<RelayDevice> devices) async {
    final pins = await loadPins();
    var dirty = false;
    final result = <TrustedDevice>[];
    for (final device in devices) {
      final fpr = device.fingerprint;
      if (fpr == null) {
        result.add(TrustedDevice(device, TrustState.noKeys));
        continue;
      }
      if (device.deviceId == me.deviceId) {
        result.add(TrustedDevice(device, fpr == me.fingerprint ? TrustState.verified : TrustState.changed));
        continue;
      }
      final pin = pins[device.deviceId];
      if (pin == null) {
        pins[device.deviceId] = DevicePin(fingerprint: fpr);
        dirty = true;
        result.add(TrustedDevice(device, TrustState.firstUse));
      } else if (pin.fingerprint != fpr) {
        result.add(TrustedDevice(device, TrustState.changed));
      } else {
        result.add(TrustedDevice(device, pin.verified ? TrustState.verified : TrustState.firstUse));
      }
    }
    if (dirty) await savePins(pins);
    return result;
  }

  Future<void> trustCurrentKey(RelayDevice device) async {
    final pins = await loadPins();
    pins[device.deviceId] = DevicePin(fingerprint: device.fingerprint!);
    await savePins(pins);
  }

  String _newDeviceId() => 'm_${base64UrlEncodeNoPad(randomBytes(16))}';

  void _checkLicense(Map<String, dynamic> license, String deviceId) {
    config.assertTrustRoots();
    final key = _signingKey;
    if (key != null) verifyEntitlement(license, key);
    final entitlement = license['entitlement'];
    if (entitlement is! Map || entitlement['deviceId'] != deviceId || entitlement['subscriptionId'] is! String) {
      throw const BindException('授权凭证与本设备不匹配');
    }
    if (entitlement['status'] != 'active') throw const BindException('订阅当前不可用');
    final features = entitlement['features'];
    if (features is List && !features.contains('relay')) throw const BindException('当前订阅未开通手机互传');
  }

  Map<String, Object?> _deviceFields(String deviceId, String deviceName, DeviceKeys keys) => {
        'deviceId': deviceId,
        'platform': platform,
        'deviceName': deviceName,
        'appVersion': AppConfig.appVersion,
        'x25519PublicKey': base64UrlEncodeNoPad(keys.x25519PublicKey),
        'ed25519PublicKey': base64UrlEncodeNoPad(keys.ed25519PublicKey),
      };

  Future<DeviceCredentials> _save(DeviceCredentials credentials, Map<String, DevicePin> pins) async {
    await store.writeJson(credentialsKey, credentials.toJson());
    await savePins(pins);
    return credentials;
  }

  Future<DeviceCredentials> bindWithUri(String uri, {required String deviceName}) async {
    final BindUri parsed;
    try {
      parsed = parseBindUri(uri.trim());
    } on RelayCryptoException {
      throw const BindException('不是有效的绑定二维码或链接');
    }
    config.assertTrustRoots();
    final server = config.serverUri(parsed.server);
    final keys = await generateDeviceKeys();
    final deviceId = _newDeviceId();
    final client = api(server);
    try {
      final result = await client.license('/mobile/bind', {
        ..._deviceFields(deviceId, deviceName, keys),
        'bindToken': parsed.bindToken,
        'bindProof': await bindProof(base64UrlDecodeNoPad(parsed.pairingSecret), keys.x25519PublicKey, keys.ed25519PublicKey),
      }, _transportKey);
      final issuerJson = result.remove('issuerDevice');
      final issuer = issuerJson is Map ? RelayDevice.fromJson(issuerJson.cast<String, dynamic>()) : null;
      if (issuer == null || issuer.deviceId != parsed.deviceId || issuer.fingerprint != parsed.fingerprint) {
        throw const BindException('电脑端设备指纹与二维码不一致，已中止绑定。请在电脑端释放本设备后重试');
      }
      _checkLicense(result, deviceId);
      return _save(
        DeviceCredentials(
          serverUrl: server.toString(),
          deviceId: deviceId,
          deviceName: deviceName,
          platform: platform,
          keys: keys,
          subscriptionId: result['entitlement']['subscriptionId'] as String,
          license: result,
          boundVia: 'qr',
          issuerDeviceId: issuer.deviceId,
        ),
        {issuer.deviceId: DevicePin(fingerprint: issuer.fingerprint!, verified: true)},
      );
    } finally {
      client.close();
    }
  }

  Future<DeviceCredentials> bindWithLicenseKey(String licenseKey, {required String deviceName}) async {
    final key = licenseKey.trim();
    if (key.isEmpty) throw const BindException('请输入授权码');
    if (config.licenseServerUrl.isEmpty) throw const BindException('应用未配置授权服务器，请使用扫码绑定');
    config.assertTrustRoots();
    final server = config.serverUri(config.licenseServerUrl);
    final keys = await generateDeviceKeys();
    final deviceId = _newDeviceId();
    final client = api(server);
    try {
      final result = await client.license('/activate', {..._deviceFields(deviceId, deviceName, keys), 'licenseKey': key}, _transportKey);
      _checkLicense(result, deviceId);
      return _save(
        DeviceCredentials(
          serverUrl: server.toString(),
          deviceId: deviceId,
          deviceName: deviceName,
          platform: platform,
          keys: keys,
          subscriptionId: result['entitlement']['subscriptionId'] as String,
          license: result,
          boundVia: 'licenseKey',
        ),
        {},
      );
    } finally {
      client.close();
    }
  }

  Future<DeviceCredentials> refresh(DeviceCredentials credentials) async {
    final client = apiFor(credentials);
    try {
      final license = await client.refreshEntitlement();
      _checkLicense(license, credentials.deviceId);
      final updated = credentials.withLicense(license);
      await store.writeJson(credentialsKey, updated.toJson());
      return updated;
    } finally {
      client.close();
    }
  }
}
