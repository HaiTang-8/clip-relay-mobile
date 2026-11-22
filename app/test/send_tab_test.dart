import 'dart:io';

import 'package:clip_relay/app/app_controller.dart';
import 'package:clip_relay/core/binding.dart';
import 'package:clip_relay/core/config.dart';
import 'package:clip_relay/core/store.dart';
import 'package:clip_relay/platform/share_intake.dart';
import 'package:clip_relay/ui/send_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:relay_crypto/relay_crypto.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'support/fake_relay.dart';

void main() {
  late FakeRelay relay;
  late Directory tmp;
  late AppController controller;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('send-tab');
    relay = FakeRelay();
    final pc = FakeDevice(deviceId: 'pc-1', platform: 'darwin', keys: await generateDeviceKeys(), name: 'PC');
    relay.devices[pc.deviceId] = pc;
    relay.bindTokens['bt'] = pc.deviceId;
    final store = MemoryKeyValueStore();
    final binding = BindingService(
      config: const AppConfig(licenseServerUrl: '', publicKey: '', transportPublicKey: '', requireTrustRoots: false),
      store: store,
      platform: 'ios',
      clientFactory: relay.clientFactory,
    );
    await binding.bindWithUri(
      buildBindUri(
        BindUri(
          server: 'https://relay.test',
          bindToken: 'bt',
          deviceId: pc.deviceId,
          fingerprint: pc.keys!.fingerprintHex,
          pairingSecret: base64UrlEncodeNoPad(generateFileKey()),
        ),
      ),
      deviceName: 'Phone',
    );
    controller = AppController(
      binding: binding,
      store: store,
      transport: MemoryBlockTransport(relay),
      workDir: Directory('${tmp.path}/work'),
    );
    await controller.init();
  });

  tearDown(() => tmp.delete(recursive: true));

  Future<void> pumpSendTab(WidgetTester tester) async {
    await tester.pumpWidget(
      ShadApp.custom(
        appBuilder: (context) => MaterialApp(
          theme: Theme.of(context),
          builder: (context, child) => ShadAppBuilder(child: child),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => SendTab(controller: controller, share: ShareIntake()),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pump();
  }

  testWidgets('sending picked images uploads them while the form is cleared', (tester) async {
    final paths = <String>[];
    for (final name in ['a.png', 'b.png']) {
      final file = File('${tmp.path}/$name')..writeAsBytesSync(img.encodePng(img.Image(width: 64, height: 64)));
      paths.add(file.path);
    }
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async => call.method == 'pickMultiImage' ? paths : null,
    );
    await pumpSendTab(tester);

    await tester.runAsync(() async => tester.tap(find.text('图片')));
    await waitFor(tester, () => find.text('a.png').evaluate().isNotEmpty);
    expect(find.text('b.png'), findsOneWidget);

    await tester.runAsync(() async => tester.tap(find.text('发送')));
    await waitFor(
      tester,
      () => relay.items.values.any((i) => i.status == 'ready') || controller.transfers.values.any((t) => t.error != null),
    );
    await waitFor(tester, () => find.text('发送成功').evaluate().isNotEmpty);

    expect(controller.transfers.values.map((t) => t.error), everyElement(isNull));
    expect(relay.items.values.where((i) => i.status == 'ready'), hasLength(1));
    expect(find.text('发送成功'), findsOneWidget);
    expect(find.text('a.png'), findsNothing);
  });

  testWidgets('tapping outside or scrolling dismisses the keyboard', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 450)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpSendTab(tester);
    bool editing() => tester.testTextInput.isVisible;

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(editing(), isTrue);
    await tester.tap(find.text('有效期'));
    await tester.pump();
    expect(editing(), isFalse);

    await tester.tap(find.byType(EditableText));
    await tester.pump();
    expect(editing(), isTrue);
    await tester.drag(find.text('有效期'), const Offset(0, -200));
    await tester.pump();
    expect(editing(), isFalse);
  });
}
