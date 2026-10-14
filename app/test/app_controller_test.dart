import 'dart:io';

import 'package:clip_relay/app/app_controller.dart';
import 'package:clip_relay/core/binding.dart';
import 'package:clip_relay/core/config.dart';
import 'package:clip_relay/core/models.dart';
import 'package:clip_relay/core/relay_api.dart';
import 'package:clip_relay/core/store.dart';
import 'package:clip_relay/platform/share_intake.dart';
import 'package:clip_relay/transfer/block_transport.dart';
import 'package:clip_relay/transfer/payload_io.dart';
import 'package:clip_relay/transfer/send_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:relay_crypto/relay_crypto.dart';

import 'support/fake_relay.dart';

void main() {
  late FakeRelay relay;
  late Directory tmp;
  late FakeDevice pc;
  late MemoryKeyValueStore store;
  late AppController controller;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('relay-controller');
    relay = FakeRelay();
    pc = FakeDevice(deviceId: 'pc-1', platform: 'darwin', keys: await generateDeviceKeys(), name: 'PC');
    relay.devices[pc.deviceId] = pc;
    relay.bindTokens['bt'] = pc.deviceId;
    store = MemoryKeyValueStore();
    final binding = BindingService(
      config: const AppConfig(licenseServerUrl: '', publicKey: '', transportPublicKey: '', requireTrustRoots: false),
      store: store,
      platform: 'android',
      clientFactory: relay.clientFactory,
    );
    await binding.bindWithUri(
      buildBindUri(BindUri(
        server: 'https://relay.test',
        bindToken: 'bt',
        deviceId: pc.deviceId,
        fingerprint: pc.keys!.fingerprintHex,
        pairingSecret: base64UrlEncodeNoPad(generateFileKey()),
      )),
      deviceName: 'Phone',
    );
    controller = AppController(binding: binding, store: store, transport: MemoryBlockTransport(relay), workDir: Directory('${tmp.path}/work'));
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<String> pcSendsFile({required bool deleteAfterPickup}) async {
    final me = DeviceCredentials(
      serverUrl: 'https://relay.test',
      deviceId: pc.deviceId,
      deviceName: 'PC',
      platform: 'darwin',
      keys: pc.keys!,
      subscriptionId: relay.subscriptionId,
      license: const {'entitlement': <String, dynamic>{}},
      boundVia: 'test',
    );
    final api = RelayApi(Uri.parse(me.serverUrl), client: relay.client, identity: DeviceIdentity.of(me));
    final file = File('${tmp.path}/report.pdf')..writeAsStringSync('pdf body');
    final result = await SendService(
      api: api,
      me: me,
      transport: MemoryBlockTransport(relay),
      workDir: Directory('${tmp.path}/pc'),
      store: MemoryKeyValueStore(),
      recipients: () async => [for (final d in await api.listDevices()) if (d.hasKeys) d],
    ).send(
      SendDraft(kind: 'files', entries: [await SourceEntry.fromFile(file.path)], deleteAfterPickup: deleteAfterPickup),
      onProgress: (_) {},
      cancel: CancelToken(),
    );
    return result.itemId;
  }

  test('init removes plaintext left over from a previous session', () async {
    final stale = File('${tmp.path}/work/received/old/secret.txt')..createSync(recursive: true);
    final picked = File('${tmp.path}/work/picked/1/a.bin')..createSync(recursive: true);
    await controller.init();
    expect(stale.existsSync(), isFalse);
    expect(picked.existsSync(), isFalse);
    expect(controller.bound, isTrue);
  });

  test('delete-after-pickup item stays reachable on the picking device until dismissed', () async {
    final itemId = await pcSendsFile(deleteAfterPickup: true);
    await controller.init();
    await controller.refresh();
    final view = controller.items.singleWhere((v) => v.item.itemId == itemId);

    final content = await controller.receive(view);
    expect(relay.items[itemId]!.status, 'deleted');
    expect(File(content.files.single.path).readAsStringSync(), 'pdf body');

    await controller.refresh();
    expect(controller.items.map((v) => v.item.itemId), contains(itemId));
    expect(controller.received[itemId], isNotNull);

    await controller.deleteItem(view.item);
    expect(controller.items.map((v) => v.item.itemId), isNot(contains(itemId)));
    expect(File(content.files.single.path).existsSync(), isFalse);
  });

  test('safeFileName cannot escape the target directory and caps length', () {
    expect(safeFileName('../../etc/passwd', 0), 'passwd');
    expect(safeFileName(r'..\..\evil.txt', 0), 'evil.txt');
    expect(safeFileName('..', 1), 'file-2');
    expect(safeFileName('...', 0), 'file-1');
    expect(safeFileName('a\u0000b', 0), 'a_b');
    final long = safeFileName('${'文' * 300}.pdf', 0);
    expect(long.endsWith('.pdf'), isTrue);
    expect(long.length, lessThan(80));
  });

  test('shared bind links are not loaded as send content', () {
    final payload = payloadFromShared([
      SharedMediaFile(path: 'cliprelay://bind?v=1&s=x', type: SharedMediaType.url),
      SharedMediaFile(path: 'hello', type: SharedMediaType.text),
    ]);
    expect(payload.text, 'hello');
  });
}
