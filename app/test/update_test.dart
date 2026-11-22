import 'dart:convert';
import 'dart:io';

import 'package:clip_relay/core/config.dart';
import 'package:clip_relay/core/store.dart';
import 'package:clip_relay/core/update.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final apk = utf8.encode('fake-apk-bytes');
  late Directory dir;
  late MemoryKeyValueStore store;
  late DateTime now;
  late List<Uri> requests;
  late Map<String, Object?> latest;
  late List<int> payload;

  UpdateService service({String server = 'https://lic.test', String version = '1.0.0', String platform = 'android'}) => UpdateService(
        config: AppConfig(licenseServerUrl: server, publicKey: '', transportPublicKey: '', requireTrustRoots: false, appVersion: version),
        store: store,
        workDir: Directory('${dir.path}/update'),
        platform: platform,
        now: () => now,
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path.endsWith('/mobile/update/latest')) return http.Response(jsonEncode(latest), 200, headers: {'content-type': 'application/json'});
          if (request.url.path.endsWith('/mobile/update/download/clip-relay-1.1.0.apk')) return http.Response.bytes(payload, 200);
          return http.Response('', 404);
        }),
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('update_test');
    store = MemoryKeyValueStore();
    now = DateTime(2026, 11, 21, 12);
    requests = [];
    payload = apk;
    latest = {
      'version': '1.1.0',
      'notes': 'fixes',
      'android': {'name': 'clip-relay-1.1.0.apk', 'size': apk.length, 'sha256': sha256.convert(apk).toString(), 'url': '/mobile/update/download/clip-relay-1.1.0.apk'},
      'ios': null,
    };
  });

  tearDown(() => dir.delete(recursive: true));

  test('compareVersions orders numeric parts and ignores build suffixes', () {
    expect(compareVersions('1.10.0', '1.9.9'), 1);
    expect(compareVersions('1.0.0', '1.0.0-build12'), 0);
    expect(compareVersions('1.0', '1.0.1'), -1);
    expect(compareVersions('2.0.0', '10.0.0'), -1);
  });

  test('check returns newer release for this platform and resolves URLs against the server', () async {
    final info = await service(server: 'https://lic.test/base/').check();
    expect(info!.version, '1.1.0');
    expect(info.notes, 'fixes');
    expect(info.asset.url.toString(), 'https://lic.test/base/mobile/update/download/clip-relay-1.1.0.apk');
    expect(requests.single.toString(), 'https://lic.test/base/mobile/update/latest');
    expect(service(server: 'https://lic.test/base').sourceUrl.toString(), 'https://lic.test/base/mobile/update/source.json');
  });

  test('check returns null when up to date or no asset for the platform', () async {
    expect(await service(version: '1.1.0').check(manual: true), isNull);
    expect(await service(version: '1.2.0').check(manual: true), isNull);
    expect(await service(platform: 'ios').check(manual: true), isNull);
  });

  test('automatic checks run at most once a day and skip ignored versions; manual checks do not', () async {
    final s = service();
    expect(await s.check(), isNotNull);
    expect(await s.check(), isNull);
    expect(requests, hasLength(1));
    expect(await s.check(manual: true), isNotNull);

    await s.ignore('1.1.0');
    now = now.add(const Duration(hours: 25));
    expect(await s.check(), isNull);
    expect(await s.check(manual: true), isNotNull);
  });

  test('check rejects missing server and malformed download URLs', () async {
    await expectLater(service(server: '').check(), throwsA(isA<UpdateException>()));
    latest = {...latest, 'android': {...(latest['android'] as Map), 'url': 'https://evil.test/x.apk'}};
    await expectLater(service().check(manual: true), throwsA(isA<UpdateException>()));
    latest = {};
    await expectLater(service().check(manual: true), completion(isNull));
  });

  test('download writes a verified file and reports progress', () async {
    final s = service();
    final info = await s.check();
    final progress = <double>[];
    final file = await s.download(info!.asset, onProgress: progress.add);
    expect(await file.readAsBytes(), apk);
    expect(file.path, endsWith('/update/clip-relay-1.1.0.apk'));
    expect(progress.last, 1.0);
  });

  test('download deletes the file when sha256 or size does not match', () async {
    final s = service();
    final info = await s.check();
    payload = utf8.encode('tampered-bytes');
    await expectLater(s.download(info!.asset), throwsA(isA<UpdateException>()));
    payload = utf8.encode('short');
    await expectLater(s.download(info.asset), throwsA(isA<UpdateException>()));
    expect(Directory('${dir.path}/update').listSync(), isEmpty);
  });

  test('download can be cancelled', () async {
    final s = service();
    final info = await s.check();
    await expectLater(s.download(info!.asset, cancelled: () => true), throwsA(isA<UpdateCancelled>()));
    expect(Directory('${dir.path}/update').listSync(), isEmpty);
  });
}
