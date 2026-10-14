import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:relay_crypto/relay_crypto.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/app_controller.dart';
import 'app.dart';
import 'widgets.dart';

String defaultDeviceName() => Platform.isIOS ? '我的 iPhone' : '我的 Android 手机';

class BindPage extends StatefulWidget {
  const BindPage({super.key, required this.controller, required this.links});

  final AppController controller;
  final DeepLinks links;

  @override
  State<BindPage> createState() => _BindPageState();
}

class _BindPageState extends State<BindPage> {
  final _name = TextEditingController(text: defaultDeviceName());
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.links.bindUri.addListener(_onLink);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onLink());
  }

  @override
  void dispose() {
    widget.links.bindUri.removeListener(_onLink);
    _name.dispose();
    super.dispose();
  }

  Future<void> _onLink() async {
    final uri = widget.links.bindUri.value;
    if (uri == null || _busy || !mounted) return;
    widget.links.bindUri.value = null;
    final BindUri parsed;
    try {
      parsed = parseBindUri(uri.trim());
    } on RelayCryptoException {
      showMessage(context, '不是有效的绑定链接');
      return;
    }
    final ok = await confirm(
      context,
      title: '确认绑定',
      description:
          '收到来自其他应用的绑定链接。\n\n'
          '服务器：${Uri.tryParse(parsed.server)?.host ?? parsed.server}\n'
          '电脑指纹：${formatFingerprint(parsed.fingerprint)}\n\n'
          '请确认这是你刚在电脑端「添加手机」中生成的，且指纹与电脑端显示一致，再继续绑定。',
      action: '绑定',
    );
    if (ok && mounted) await _bind(() => widget.controller.bindWithUri(uri, _deviceName));
  }

  String get _deviceName => _name.text.trim().isEmpty ? defaultDeviceName() : _name.text.trim();

  Future<void> _bind(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        await showShadDialog<void>(
          context: context,
          builder: (context) => ShadDialog.alert(
            title: const Text('绑定失败'),
            description: Text('$error'),
            actions: [ShadButton(onPressed: () => Navigator.pop(context), child: const Text('好'))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final uri = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (uri != null) await _bind(() => widget.controller.bindWithUri(uri, _deviceName));
  }

  Future<void> _pasteLink() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    final input = TextEditingController(text: clip.startsWith('cliprelay://') ? clip : '');
    final uri = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('粘贴绑定链接'),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ShadButton(onPressed: () => Navigator.pop(context, input.text.trim()), child: const Text('绑定')),
        ],
        child: ShadTextarea(controller: input, minHeight: 80, maxHeight: 140, placeholder: const Text('cliprelay://bind?...')),
      ),
    );
    if (uri != null && uri.isNotEmpty) await _bind(() => widget.controller.bindWithUri(uri, _deviceName));
  }

  Future<void> _licenseKey() async {
    final input = TextEditingController();
    final key = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('使用授权码绑定'),
        description: const Text('绑定后请在电脑端核对本机指纹。'),
        actions: [
          ShadButton.outline(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ShadButton(onPressed: () => Navigator.pop(context, input.text.trim()), child: const Text('绑定')),
        ],
        child: ShadInput(controller: input, autocorrect: false, placeholder: const Text('授权码')),
      ),
    );
    if (key != null && key.isNotEmpty) await _bind(() => widget.controller.bindWithLicenseKey(key, _deviceName));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final notice = widget.controller.notice;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Center(child: IconTile(LucideIcons.smartphoneNfc, size: 72)),
            const SizedBox(height: 20),
            Text('超级剪切板', textAlign: TextAlign.center, style: theme.textTheme.h3),
            const SizedBox(height: 8),
            Text('请在电脑端扫码绑定', textAlign: TextAlign.center, style: theme.textTheme.large),
            const SizedBox(height: 8),
            Text('在电脑端打开「超级剪切板」→ 手机互传 → 添加手机，然后用本应用扫描二维码。', textAlign: TextAlign.center, style: theme.mutedText),
            if (notice != null) ...[
              const SizedBox(height: 16),
              ShadAlert.destructive(icon: const Icon(LucideIcons.circleAlert), description: Text(notice)),
            ],
            const SizedBox(height: 32),
            Text('本机名称', style: theme.textTheme.small),
            const SizedBox(height: 8),
            ShadInput(controller: _name, enabled: !_busy, maxLength: 64),
            const SizedBox(height: 20),
            if (_busy)
              const Center(
                child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
              )
            else ...[
              ShadButton(
                onPressed: _scan,
                size: ShadButtonSize.lg,
                leading: const Icon(LucideIcons.scanLine, size: 18),
                child: const Text('扫描二维码'),
              ),
              const SizedBox(height: 12),
              ShadButton.outline(
                onPressed: _pasteLink,
                size: ShadButtonSize.lg,
                leading: const Icon(LucideIcons.link, size: 18),
                child: const Text('粘贴绑定链接'),
              ),
              const SizedBox(height: 4),
              ShadButton.ghost(onPressed: _licenseKey, child: const Text('使用授权码绑定')),
            ],
          ],
        ),
      ),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final value = code.rawValue;
      if (value != null && value.startsWith('cliprelay://bind')) {
        _done = true;
        Navigator.pop(context, value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描绑定二维码')),
    body: Stack(
      children: [
        MobileScanner(
          controller: _scanner,
          onDetect: _onDetect,
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('无法打开相机：${error.errorDetails?.message ?? error.errorCode.name}\n可改用「粘贴绑定链接」。', textAlign: TextAlign.center),
            ),
          ),
        ),
        const Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('对准电脑端显示的二维码', style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ),
      ],
    ),
  );
}
