import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../core/update.dart';
import '../platform/installer.dart';
import 'app.dart';
import 'format.dart';
import 'widgets.dart';

enum _Choice { update, later, ignore }

Future<void> checkForUpdate(BuildContext context, UpdateService service, {bool manual = false}) async {
  final UpdateInfo? info;
  try {
    info = await service.check(manual: manual);
  } on UpdateException catch (e) {
    if (manual && context.mounted) showMessage(context, e);
    return;
  }
  if (!context.mounted) return;
  if (info == null) {
    if (manual) showMessage(context, '已是最新版本 v${service.currentVersion}');
    return;
  }
  final choice = await showShadDialog<_Choice>(
    context: context,
    builder: (context) => ShadDialog(
      title: Text('发现新版本 v${info!.version}'),
      description: Text('当前 v${service.currentVersion} · 安装包 ${formatBytes(info.asset.size)}'),
      actions: [
        if (!manual) ShadButton.ghost(onPressed: () => Navigator.pop(context, _Choice.ignore), child: const Text('忽略此版本')),
        ShadButton.outline(onPressed: () => Navigator.pop(context, _Choice.later), child: const Text('稍后')),
        ShadButton(onPressed: () => Navigator.pop(context, _Choice.update), child: const Text('立即更新')),
      ],
      child: info.notes.trim().isEmpty
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(child: Text(info.notes.trim(), style: ShadTheme.of(context).mutedText.copyWith(fontSize: 13))),
            ),
    ),
  );
  if (choice == _Choice.ignore) await service.ignore(info.version);
  if (choice == _Choice.update && context.mounted) {
    await showShadDialog<void>(context: context, barrierDismissible: false, builder: (_) => _DownloadDialog(service: service, info: info!));
  }
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.service, required this.info});

  final UpdateService service;
  final UpdateInfo info;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  double _progress = 0;
  File? _file;
  String? _error;
  bool _cancelled = false;

  bool get _ios => widget.service.platform == 'ios';

  @override
  void initState() {
    super.initState();
    _download();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _download() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    try {
      final file = await widget.service.download(
        widget.info.asset,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
        cancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() => _file = file);
      await _install();
    } on UpdateCancelled {
      return;
    } on UpdateException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _install() async {
    final file = _file!;
    if (_ios) {
      await shareIpa(file, context);
      return;
    }
    try {
      if (!await installApk(file) && mounted) showMessage(context, '请允许本应用安装未知应用，返回后点「安装」');
    } catch (e) {
      if (mounted) setState(() => _error = '无法打开安装程序：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.service.sourceUrl;
    final ready = _file != null;
    return ShadDialog(
      title: Text(ready ? '下载完成' : '正在下载 v${widget.info.version}'),
      description: Text(
        _error ??
            (ready
                ? (_ios ? '在分享面板中选择「全能签」导入，签名后安装。也可以在全能签中添加软件源，以后直接在全能签里更新。' : '在系统安装界面确认安装。')
                : '${(_progress * 100).toStringAsFixed(0)}% · ${formatBytes(widget.info.asset.size)}'),
      ),
      actions: [
        ShadButton.outline(onPressed: () => Navigator.pop(context), child: Text(ready ? '关闭' : '取消')),
        if (_error != null && !ready) ShadButton(onPressed: _download, child: const Text('重试')),
        if (ready && _ios && source != null)
          ShadButton.outline(onPressed: () => copyText(context, source.toString(), done: '软件源地址已复制'), child: const Text('复制软件源')),
        if (ready) ShadButton(onPressed: _install, child: Text(_ios ? '分享给全能签' : '安装')),
      ],
      child: ready || _error != null ? null : Padding(padding: const EdgeInsets.only(top: 8), child: ShadProgress(value: _progress)),
    );
  }
}
