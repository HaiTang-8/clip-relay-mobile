import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PastedContent {
  const PastedContent({this.text, this.imagePath});

  final String? text;
  final String? imagePath;
}

const _channel = MethodChannel('cliprelay/paste');

class PasteButton extends StatefulWidget {
  const PasteButton({super.key, required this.onPasted});

  final ValueChanged<PastedContent> onPasted;

  @override
  State<PasteButton> createState() => _PasteButtonState();
}

class _PasteButtonState extends State<PasteButton> {
  static bool? _nativeSupported;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onCall);
    if (Platform.isIOS && _nativeSupported == null) {
      _channel
          .invokeMethod<bool>('isSupported')
          .then(
            (value) {
              if (mounted) setState(() => _nativeSupported = value == true);
            },
            onError: (_) {
              if (mounted) setState(() => _nativeSupported = false);
            },
          );
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'pasted') return;
    final args = (call.arguments as Map).cast<String, Object?>();
    widget.onPasted(PastedContent(text: args['text'] as String?, imagePath: args['imagePath'] as String?));
  }

  Future<void> _fallback() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    widget.onPasted(PastedContent(text: data?.text));
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS && _nativeSupported == true) {
      return const SizedBox(
        height: 44,
        width: 140,
        child: UiKitView(viewType: 'cliprelay/paste_button', creationParamsCodec: StandardMessageCodec()),
      );
    }
    return ShadButton.secondary(
      onPressed: Platform.isIOS && _nativeSupported == null ? null : _fallback,
      leading: const Icon(LucideIcons.clipboardPaste, size: 16),
      child: const Text('粘贴'),
    );
  }
}
