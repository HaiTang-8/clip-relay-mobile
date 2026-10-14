import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

class SharedPayload {
  const SharedPayload({this.text, this.files = const []});

  final String? text;
  final List<String> files;

  bool get isEmpty => (text == null || text!.isEmpty) && files.isEmpty;
}

SharedPayload payloadFromShared(List<SharedMediaFile> media) {
  final texts = <String>[];
  final files = <String>[];
  for (final item in media) {
    if (item.path.startsWith('cliprelay:')) continue;
    switch (item.type) {
      case SharedMediaType.text:
      case SharedMediaType.url:
        if (item.path.isNotEmpty) texts.add(item.path);
      case SharedMediaType.image:
      case SharedMediaType.video:
      case SharedMediaType.file:
        final path = item.path.startsWith('file://') ? Uri.parse(item.path).toFilePath() : item.path;
        if (path.isNotEmpty) files.add(path);
    }
    if (item.message?.isNotEmpty == true) texts.add(item.message!);
  }
  return SharedPayload(text: texts.isEmpty ? null : texts.join('\n'), files: files);
}

class ShareIntake {
  final ValueNotifier<SharedPayload?> pending = ValueNotifier(null);
  StreamSubscription<List<SharedMediaFile>>? _subscription;

  Future<void> start() async {
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    _subscription = ReceiveSharingIntent.instance.getMediaStream().listen(_accept, onError: (_) {});
    _accept(await ReceiveSharingIntent.instance.getInitialMedia());
  }

  void _accept(List<SharedMediaFile> media) {
    if (media.isEmpty) return;
    final payload = payloadFromShared(media);
    if (!payload.isEmpty) pending.value = payload;
    ReceiveSharingIntent.instance.reset();
  }

  SharedPayload? take() {
    final value = pending.value;
    pending.value = null;
    return value;
  }

  void dispose() {
    _subscription?.cancel();
    pending.dispose();
  }
}
