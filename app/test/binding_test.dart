import 'package:clip_relay/core/binding.dart';
import 'package:clip_relay/core/config.dart';
import 'package:clip_relay/core/license_crypto.dart';
import 'package:clip_relay/core/models.dart';
import 'package:clip_relay/core/relay_api.dart';
import 'package:clip_relay/core/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_crypto/relay_crypto.dart';

import 'support/fake_relay.dart';
import 'support/rsa_test_keys.dart';

void main() {
  late FakeRelay relay;
  late FakeDevice pc;
  late MemoryKeyValueStore store;
  late BindingService service;
  late List<int> pairingSecret;
  const server = 'https://relay.test';

  String bindUri({String token = 'bt_token', String? fpr, String s = server}) => buildBindUri(BindUri(
        server: s,
        bindToken: token,
        deviceId: pc.deviceId,
        fingerprint: fpr ?? pc.keys!.fingerprintHex,
        pairingSecret: base64UrlEncodeNoPad(pairingSecret),
      ));

  setUp(() async {
    relay = FakeRelay();
    pc = FakeDevice(deviceId: 'pc-1', platform: 'darwin', keys: await generateDeviceKeys(), name: '办公室电脑');
    relay.devices[pc.deviceId] = pc;
    relay.bindTokens['bt_token'] = pc.deviceId;
    pairingSecret = generateFileKey();
    store = MemoryKeyValueStore();
    service = BindingService(
      config: AppConfig(licenseServerUrl: server, publicKey: testPublicKeyPem, transportPublicKey: testPublicKeyPem, requireTrustRoots: true),
      store: store,
      platform: 'ios',
      clientFactory: relay.clientFactory,
    );
  });

  test('QR binding registers keys with a valid bind proof and pins the PC as verified', () async {
    final credentials = await service.bindWithUri(bindUri(), deviceName: '测试 iPhone');
    final registered = relay.devices[credentials.deviceId]!;
    expect(registered.platform, 'ios');
    expect(registered.name, '测试 iPhone');
    expect(registered.boundBy, pc.deviceId);
    expect(await verifyBindProof(registered.bindProof!, pairingSecret, credentials.keys.x25519PublicKey, credentials.keys.ed25519PublicKey), isTrue);
    expect(registered.keys!.fingerprintHex, credentials.fingerprint);
    expect(credentials.subscriptionId, relay.subscriptionId);
    expect(credentials.boundVia, 'qr');
    expect((await service.load())!.deviceId, credentials.deviceId);
    expect((await service.loadPins())[pc.deviceId]!.verified, isTrue);
    expect(relay.log, ['POST /mobile/bind']);
  });

  test('QR binding aborts when the PC fingerprint does not match the QR code', () async {
    final other = await generateDeviceKeys();
    await expectLater(service.bindWithUri(bindUri(fpr: other.fingerprintHex), deviceName: 'x'), throwsA(isA<BindException>()));
    expect(await service.load(), isNull);
  });

  test('reused bind token and malformed links fail with Chinese messages', () async {
    await service.bindWithUri(bindUri(), deviceName: 'a');
    await expectLater(
      service.bindWithUri(bindUri(), deviceName: 'b'),
      throwsA(isA<RelayApiException>().having((e) => e.userMessage, 'message', contains('二维码无效'))),
    );
    await expectLater(service.bindWithUri('cliprelay://bind?v=1&s=x', deviceName: 'c'), throwsA(isA<BindException>()));
    await expectLater(service.bindWithUri('https://example.com', deviceName: 'c'), throwsA(isA<BindException>()));
  });

  test('encrypted license request rejects a plaintext success response', () async {
    relay.plaintextLicenseResponses = true;
    await expectLater(service.bindWithLicenseKey('DEV-CLIPBOARD-PRO', deviceName: 'a'), throwsA(isA<LicenseException>()));
    await expectLater(
      service.bindWithLicenseKey('WRONG', deviceName: 'a'),
      throwsA(isA<RelayApiException>().having((e) => e.userMessage, 'message', '授权码无效')),
    );
    expect(await service.load(), isNull);
  });

  test('release config rejects plain HTTP servers', () async {
    await expectLater(service.bindWithUri(bindUri(s: 'http://relay.test'), deviceName: 'a'), throwsA(isA<ConfigException>()));
  });

  test('device limit surfaces the release-a-device hint', () async {
    relay.maxDevices = 1;
    await expectLater(
      service.bindWithUri(bindUri(), deviceName: 'a'),
      throwsA(isA<RelayApiException>().having((e) => e.userMessage, 'message', contains('释放设备'))),
    );
  });

  test('license key binding uses encrypted transport and trust on first use', () async {
    final credentials = await service.bindWithLicenseKey(' DEV-CLIPBOARD-PRO ', deviceName: '安卓');
    expect(credentials.boundVia, 'licenseKey');
    expect(relay.devices[credentials.deviceId]!.platform, 'ios');
    expect(await service.loadPins(), isEmpty);
    await expectLater(
      service.bindWithLicenseKey('WRONG', deviceName: 'x'),
      throwsA(isA<RelayApiException>().having((e) => e.userMessage, 'message', '授权码无效')),
    );
  });

  test('entitlement refresh is a signed relay request and is verified', () async {
    final credentials = await service.bindWithUri(bindUri(), deviceName: 'a');
    final refreshed = await service.refresh(credentials);
    expect(refreshed.entitlement['deviceId'], credentials.deviceId);
    expect(relay.log.last, 'POST /relay/entitlement');
    relay.devices[credentials.deviceId]!.active = false;
    await expectLater(service.refresh(credentials), throwsA(isA<RelayApiException>().having((e) => e.code, 'code', 'device_inactive')));
  });

  test('reconcile pins unknown devices and flags changed fingerprints', () async {
    final me = await service.bindWithUri(bindUri(), deviceName: 'a');
    final other = FakeDevice(deviceId: 'pc-2', platform: 'win32', keys: await generateDeviceKeys());
    relay.devices[other.deviceId] = other;
    final api = service.apiFor(me);
    var trusted = await service.reconcile(me, await api.listDevices());
    TrustState stateOf(String id) => trusted.firstWhere((t) => t.device.deviceId == id).trust;
    expect(stateOf(pc.deviceId), TrustState.verified);
    expect(stateOf(other.deviceId), TrustState.firstUse);
    expect(stateOf(me.deviceId), TrustState.verified);

    other.keys = await generateDeviceKeys();
    trusted = await service.reconcile(me, await api.listDevices());
    expect(stateOf(other.deviceId), TrustState.changed);
    expect(trusted.firstWhere((t) => t.device.deviceId == other.deviceId).usable, isFalse);

    await service.trustCurrentKey(RelayDevice.fromJson(other.toJson()));
    trusted = await service.reconcile(me, await api.listDevices());
    expect(stateOf(other.deviceId), TrustState.firstUse);
  });
}
