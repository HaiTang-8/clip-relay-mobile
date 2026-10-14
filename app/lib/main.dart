import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_controller.dart';
import 'core/binding.dart';
import 'core/config.dart';
import 'core/store.dart';
import 'platform/share_intake.dart';
import 'transfer/background_transport.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final links = DeepLinks()..attach();
  final store = SecureKeyValueStore();
  final controller = AppController(
    binding: BindingService(config: AppConfig.fromEnvironment(), store: store, platform: Platform.isIOS ? 'ios' : 'android'),
    store: store,
    transport: BackgroundBlockTransport(requireHttps: kReleaseMode),
    workDir: Directory('${(await getTemporaryDirectory()).path}/relay'),
  );
  final share = ShareIntake();
  runApp(ClipRelayApp(controller: controller, share: share, links: links));
  await controller.init();
  await share.start();
}
