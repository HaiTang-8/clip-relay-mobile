import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clip_relay/app/app_controller.dart';
import 'package:clip_relay/core/binding.dart';
import 'package:clip_relay/core/config.dart';
import 'package:clip_relay/core/store.dart';
import 'package:clip_relay/platform/share_intake.dart';
import 'package:clip_relay/transfer/background_transport.dart';
import 'package:clip_relay/transfer/payload_io.dart';
import 'package:clip_relay/transfer/send_service.dart';
import 'package:clip_relay/ui/app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Run against a live relay server (the dev harness lives in the private server repo):
// flutter test integration_test/relay_e2e_test.dart -d <simulator> \
//   --dart-define-from-file=config/relay.e2e.json --dart-define=E2E_BIND_URI="$(cat $TMPDIR/cliprelay-bind-uri.txt)"
const bindUri = String.fromEnvironment('E2E_BIND_URI');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bind, receive from PC, send to PC against the live harness', (tester) async {
    final store = SecureKeyValueStore();
    final config = AppConfig.fromEnvironment();
    expect(config.publicKey, isNotEmpty, reason: 'run with --dart-define-from-file=config/relay.e2e.json');
    final controller = AppController(
      binding: BindingService(config: config, store: store, platform: 'ios'),
      store: store,
      transport: BackgroundBlockTransport(),
      workDir: Directory('${(await getTemporaryDirectory()).path}/relay-e2e'),
    );
    await controller.init();
    if (controller.bound) await controller.unbind();

    await controller.bindWithUri(bindUri, 'E2E iPhone');
    expect(controller.credentials!.boundVia, 'qr');
    expect((await controller.binding.loadPins())['pc-sim']!.verified, isTrue);

    for (var i = 0; i < 30 && controller.items.where((v) => v.item.senderDeviceId == 'pc-sim').length < 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      await controller.refresh();
    }
    final fromPc = controller.items.where((v) => v.item.senderDeviceId == 'pc-sim').toList();
    expect(fromPc, hasLength(2));
    expect(controller.devices.firstWhere((d) => d.device.deviceId == 'pc-sim').usable, isTrue);

    final textView = fromPc.firstWhere((v) => v.opened?.manifest.kind == 'text');
    final text = await controller.receive(textView);
    expect(text.text, '来自电脑的测试文本 ✅');

    final fileView = fromPc.firstWhere((v) => v.opened?.manifest.kind == 'files');
    final files = await controller.receive(fileView);
    expect(files.files.single.name, '电脑文件.bin');
    expect(await File(files.files.single.path).length(), 9 * 1024 * 1024 + 123);

    final sentText = await controller.send(
      SendDraft(kind: 'text', entries: [SourceEntry.bytes(utf8.encode('来自手机的文本 📱'), name: '', mime: 'text/plain; charset=utf-8')], preview: '来自手机的文本 📱'),
      title: 'text',
    );
    expect(sentText.pickupCode, hasLength(6));

    final big = File('${(await getTemporaryDirectory()).path}/手机大文件.bin');
    await big.writeAsBytes(Uint8List.fromList(List.generate(17 * 1024 * 1024 + 5, (i) => (i * 7 + 1) & 0xff)));
    final sentFile = await controller.send(
      SendDraft(kind: 'files', entries: [await SourceEntry.fromFile(big.path)], expiresIn: '1h', deleteAfterPickup: true),
      title: 'file',
    );
    expect(sentFile.pickupCode, hasLength(6));
    await controller.refresh();
    expect(controller.items.map((v) => v.item.pickupCode), containsAll([sentText.pickupCode, sentFile.pickupCode]));
    expect(controller.outbox, isEmpty);

    final share = ShareIntake();
    await tester.pumpWidget(ClipRelayApp(controller: controller, share: share, links: DeepLinks()));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('待取件'), findsOneWidget);
    expect(find.textContaining('来自电脑的测试文本'), findsWidgets);

    for (var i = 0; i < 10 && controller.items.any((v) => v.item.pickupCode == sentFile.pickupCode); i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      await controller.refresh();
    }
    expect(controller.items.any((v) => v.item.pickupCode == sentFile.pickupCode), isFalse, reason: 'PC ack deletes delete-after-pickup items');

    await controller.unbind();
    expect(await controller.binding.load(), isNull);
  });
}
