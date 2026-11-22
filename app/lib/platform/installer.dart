import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

const _channel = MethodChannel('clip_relay/installer');

/// Returns false when the user must first allow installing unknown apps (settings page has been opened).
Future<bool> installApk(File apk) async => await _channel.invokeMethod<bool>('installApk', {'path': apk.path}) ?? false;

Future<void> shareIpa(File ipa, BuildContext context) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    files: [XFile(ipa.path, mimeType: 'application/octet-stream')],
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}
