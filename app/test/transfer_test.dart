import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_relay/core/binding.dart';
import 'package:clip_relay/core/config.dart';
import 'package:clip_relay/core/models.dart';
import 'package:clip_relay/core/relay_api.dart';
import 'package:clip_relay/core/store.dart';
import 'package:clip_relay/transfer/block_transport.dart';
import 'package:clip_relay/transfer/payload_io.dart';
import 'package:clip_relay/transfer/receive_service.dart';
import 'package:clip_relay/transfer/send_service.dart';
import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_crypto/relay_crypto.dart';

import 'support/fake_relay.dart';

Uint8List pattern(int length, [int seed = 7]) => Uint8List.fromList(List.generate(length, (i) => (i * 131 + seed) & 0xff));

void main() {
  late FakeRelay relay;
  late MemoryBlockTransport transport;
  late Directory tmp;
  late DeviceCredentials phone;
  late DeviceCredentials pcCredentials;
  late MemoryKeyValueStore phoneStore;
  final progress = <TransferProgress>[];

  DeviceCredentials credentialsFor(FakeDevice device) => DeviceCredentials(
        serverUrl: 'https://relay.test',
        deviceId: device.deviceId,
        deviceName: device.name ?? device.deviceId,
        platform: device.platform,
        keys: device.keys!,
        subscriptionId: relay.subscriptionId,
        license: const {'entitlement': <String, dynamic>{}},
        boundVia: 'test',
      );

  RelayApi apiFor(DeviceCredentials me) => RelayApi(Uri.parse(me.serverUrl), client: relay.client, identity: DeviceIdentity.of(me));

  SendService sender() {
    final api = apiFor(phone);
    return SendService(
      api: api,
      me: phone,
      transport: transport,
      workDir: Directory('${tmp.path}/phone'),
      store: phoneStore,
      retryDelay: Duration.zero,
      recipients: () async => [for (final d in await api.listDevices()) if (d.hasKeys) d],
    );
  }

  ReceiveService receiver(DeviceCredentials me) =>
      ReceiveService(api: apiFor(me), me: me, transport: transport, workDir: Directory('${tmp.path}/${me.deviceId}'), retryDelay: Duration.zero);

  List<int>? senderKey(String id) => relay.devices[id]?.keys?.ed25519PublicKey;

  Future<RelayItem> serverItem(String itemId, DeviceCredentials viewer) async =>
      (await apiFor(viewer).listItems()).firstWhere((item) => item.itemId == itemId);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('relay-transfer');
    relay = FakeRelay();
    transport = MemoryBlockTransport(relay);
    phoneStore = MemoryKeyValueStore();
    final pc = FakeDevice(deviceId: 'pc-1', platform: 'darwin', keys: await generateDeviceKeys(), name: 'PC');
    relay.devices[pc.deviceId] = pc;
    relay.bindTokens['bt'] = pc.deviceId;
    pcCredentials = credentialsFor(pc);
    phone = await BindingService(
      config: const AppConfig(licenseServerUrl: '', publicKey: '', transportPublicKey: '', requireTrustRoots: false),
      store: MemoryKeyValueStore(),
      platform: 'android',
      clientFactory: relay.clientFactory,
    ).bindWithUri(
      buildBindUri(BindUri(
        server: 'https://relay.test',
        bindToken: 'bt',
        deviceId: pc.deviceId,
        fingerprint: pc.keys!.fingerprintHex,
        pairingSecret: base64UrlEncodeNoPad(generateFileKey()),
      )),
      deviceName: 'Phone',
    );
    progress.clear();
  });

  tearDown(() => tmp.delete(recursive: true));

  test('inline text round trip, receiver acks and delete-after-pickup removes it', () async {
    const text = '你好，PC 👋\nline 2';
    final result = await sender().send(
      SendDraft(kind: 'text', entries: [SourceEntry.bytes(utf8.encode(text), name: '', mime: 'text/plain; charset=utf-8')], preview: text, deleteAfterPickup: true),
      onProgress: progress.add,
      cancel: CancelToken(),
    );
    expect(result.pickupCode, hasLength(6));
    expect(relay.items[result.itemId]!.inline, isNotNull);
    expect(relay.items[result.itemId]!.recipients, unorderedEquals(['pc-1', phone.deviceId]));

    final item = await apiFor(pcCredentials).findByCode(result.pickupCode);
    final opened = await receiver(pcCredentials).open(item, senderKey);
    expect(opened.manifest.kind, 'text');
    expect(opened.manifest.text, text);
    final content = await receiver(pcCredentials).download(opened, onProgress: progress.add, cancel: CancelToken());
    expect(content.text, text);

    expect(await apiFor(phone).ack(result.itemId), isFalse, reason: 'sender ack never deletes');
    expect(await apiFor(pcCredentials).ack(result.itemId), isTrue);
    expect(relay.items[result.itemId]!.status, 'deleted');
  });

  test('multi-block files upload as 8 MiB blocks and decrypt byte-exact on another device', () async {
    final big = File('${tmp.path}/大文件.bin')..writeAsBytesSync(pattern(blockSize + 70000));
    final small = File('${tmp.path}/note.txt')..writeAsStringSync('small file');
    final result = await sender().send(
      SendDraft(kind: 'files', entries: [await SourceEntry.fromFile(big.path), await SourceEntry.fromFile(small.path)]),
      onProgress: progress.add,
      cancel: CancelToken(),
    );
    expect(transport.uploaded, [0, 1]);
    expect(relay.objects.keys, hasLength(2));
    expect(relay.objects.values.first.length, blockSize);
    expect(progress.map((p) => p.phase).toSet(), containsAll([TransferPhase.preparing, TransferPhase.encrypting, TransferPhase.uploading]));
    expect(Directory('${tmp.path}/phone/outbox/${result.itemId}').existsSync(), isFalse);
    expect(await sender().pendingJobs(), isEmpty);

    final service = receiver(pcCredentials);
    final opened = await service.open(await serverItem(result.itemId, pcCredentials), senderKey);
    expect(opened.manifest.entries.map((e) => e.name), ['大文件.bin', 'note.txt']);
    final content = await service.download(opened, onProgress: progress.add, cancel: CancelToken());
    expect(content.files.map((f) => f.name), ['大文件.bin', 'note.txt']);
    expect(hash.sha256.convert(File(content.files[0].path).readAsBytesSync()), hash.sha256.convert(big.readAsBytesSync()));
    expect(File(content.files[1].path).readAsStringSync(), 'small file');

    final own = await receiver(phone).open(await serverItem(result.itemId, phone), senderKey);
    expect(own.plaintextSize, big.lengthSync() + small.lengthSync());
  });

  test('failed block upload keeps the job and resume uploads only missing blocks', () async {
    final file = File('${tmp.path}/photo.jpg')..writeAsBytesSync(pattern(blockSize + 1000, 3));
    transport.failUploads[1] = SendService.maxBlockAttempts;
    await expectLater(
      sender().send(SendDraft(kind: 'image', entries: [await SourceEntry.fromFile(file.path)]), onProgress: progress.add, cancel: CancelToken()),
      throwsA(isA<TransferException>()),
    );
    final jobs = await sender().pendingJobs();
    expect(jobs, hasLength(1));
    expect(transport.uploaded, [0]);

    final result = await sender().resume(jobs.values.single, onProgress: progress.add, cancel: CancelToken());
    expect(transport.uploaded, [0, 1]);
    expect(relay.items[result.itemId]!.status, 'ready');
    expect(await sender().pendingJobs(), isEmpty);
    final opened = await receiver(pcCredentials).open(await serverItem(result.itemId, pcCredentials), senderKey);
    final content = await receiver(pcCredentials).download(opened, onProgress: progress.add, cancel: CancelToken());
    expect(content.files.single.isImage, isTrue);
    expect(File(content.files.single.path).readAsBytesSync(), file.readAsBytesSync());
  });

  test('recipients_outdated triggers a re-wrap and second commit', () async {
    relay.rejectCommits = 1;
    final result = await sender().send(
      SendDraft(kind: 'text', entries: [SourceEntry.bytes(utf8.encode('retry'), name: '', mime: 'text/plain')]),
      onProgress: progress.add,
      cancel: CancelToken(),
    );
    expect(relay.log.where((line) => line.endsWith('/commit')), hasLength(2));
    expect(relay.items[result.itemId]!.status, 'ready');
  });

  test('device bound after sending cannot decrypt the item', () async {
    final result = await sender().send(
      SendDraft(kind: 'text', entries: [SourceEntry.bytes(utf8.encode('old'), name: '', mime: 'text/plain')]),
      onProgress: progress.add,
      cancel: CancelToken(),
    );
    final late = FakeDevice(deviceId: 'pc-late', platform: 'win32', keys: await generateDeviceKeys());
    relay.devices[late.deviceId] = late;
    final lateCredentials = credentialsFor(late);
    final item = await serverItem(result.itemId, lateCredentials);
    expect(item.decryptable, isFalse);
    await expectLater(receiver(lateCredentials).open(item, senderKey), throwsA(isA<UndecryptableException>()));
    expect(const UndecryptableException().toString(), '此设备无法解密，请让发送方重新发送');
  });

  test('tampered block fails decryption and leaves no output files', () async {
    final file = File('${tmp.path}/a.bin')..writeAsBytesSync(pattern(blockSize + 10));
    final result = await sender().send(
      SendDraft(kind: 'files', entries: [await SourceEntry.fromFile(file.path)]),
      onProgress: progress.add,
      cancel: CancelToken(),
    );
    relay.objects['${result.itemId}/0']![100] ^= 1;
    final service = receiver(pcCredentials);
    final opened = await service.open(await serverItem(result.itemId, pcCredentials), senderKey);
    await expectLater(service.download(opened, onProgress: progress.add, cancel: CancelToken()), throwsA(isA<TransferException>()));
    final out = service.receivedDir(result.itemId);
    expect(out.existsSync() ? out.listSync() : const [], isEmpty);
  });

  test('tampered header is rejected before unwrapping', () async {
    final result = await sender().send(
      SendDraft(kind: 'text', entries: [SourceEntry.bytes(utf8.encode('x'), name: '', mime: 'text/plain')]),
      onProgress: progress.add,
      cancel: CancelToken(),
    );
    relay.items[result.itemId]!.header!['encManifest'] = relay.items[result.itemId]!.header!['encManifest'].toString().replaceRange(0, 2, 'AA');
    await expectLater(
      receiver(pcCredentials).open(await serverItem(result.itemId, pcCredentials), senderKey),
      throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('校验失败'))),
    );
    await expectLater(receiver(pcCredentials).open(await serverItem(result.itemId, pcCredentials), (_) => null), throwsA(isA<TransferException>()));
  });

  test('cancel during upload deletes the server item and local job', () async {
    final file = File('${tmp.path}/c.bin')..writeAsBytesSync(pattern(blockSize * 2));
    final cancel = CancelToken();
    transport.onUpload = (index) {
      if (index == 1) cancel.cancel();
    };
    await expectLater(
      sender().send(SendDraft(kind: 'files', entries: [await SourceEntry.fromFile(file.path)]), onProgress: progress.add, cancel: cancel),
      throwsA(isA<TransferCancelled>()),
    );
    expect(relay.items.values.single.status, 'deleted');
    expect(await sender().pendingJobs(), isEmpty);
    expect(Directory('${tmp.path}/phone/outbox').listSync(), isEmpty);
  });

  test('oversized items are rejected before contacting the server', () async {
    final file = File('${tmp.path}/huge.bin')..writeAsBytesSync([1]);
    await expectLater(
      sender().send(
        SendDraft(kind: 'files', entries: [SourceEntry.file(file.path, name: 'huge.bin', mime: 'application/octet-stream', size: maxPlaintextBytes + 1)]),
        onProgress: progress.add,
        cancel: CancelToken(),
      ),
      throwsA(isA<TransferException>().having((e) => e.message, 'message', contains('100 MB'))),
    );
    expect(relay.log, ['POST /mobile/bind']);
  });

  test('EntrySink splits a stream into entries and checks hashes', () async {
    String sha(List<int> data) => hash.sha256.convert(data).toString();
    final a = pattern(10), b = Uint8List(0), c = pattern(5, 9);
    final manifest = Manifest(kind: 'files', entries: [
      ManifestEntry(name: '../evil.txt', mime: 'text/plain', size: 10, sha256: sha(a), offset: 0),
      ManifestEntry(name: 'empty', mime: 'text/plain', size: 0, sha256: sha(b), offset: 10),
      ManifestEntry(name: 'evil.txt', mime: 'text/plain', size: 5, sha256: sha(c), offset: 10),
    ])..validate(15);
    final dir = await Directory('${tmp.path}/sink').create();
    final sink = EntrySink(manifest, directory: dir);
    await sink.add([...a.sublist(0, 7)]);
    await sink.add([...a.sublist(7), ...c]);
    await sink.close();
    expect(sink.files.map((f) => f.name), ['evil.txt', 'empty', 'evil (2).txt']);
    expect(File(sink.files[2].path).readAsBytesSync(), c);

    final bad = EntrySink(manifest, directory: await Directory('${tmp.path}/sink2').create());
    await expectLater(bad.add(pattern(15)), throwsA(isA<FormatException>()));
  });
}
