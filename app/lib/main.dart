import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_controller.dart';
import 'core/binding.dart';
import 'core/config.dart';
import 'core/store.dart';
import 'core/update.dart';
import 'platform/share_intake.dart';
import 'transfer/background_transport.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final links = DeepLinks()..attach();
  final store = SecureKeyValueStore();
  final config = AppConfig.fromEnvironment(appVersion: (await PackageInfo.fromPlatform()).version);
  final platform = Platform.isIOS ? 'ios' : 'android';
  final temp = (await getTemporaryDirectory()).path;
  final controller = AppController(
    binding: BindingService(config: config, store: store, platform: platform),
    store: store,
    transport: BackgroundBlockTransport(requireHttps: kReleaseMode),
    workDir: Directory('$temp/relay'),
  );
  final update = UpdateService(config: config, store: store, workDir: Directory('$temp/update'), platform: platform);
  final share = ShareIntake();
  runApp(ClipRelayApp(controller: controller, share: share, links: links, update: update));
  await controller.init();
  await share.start();
}
