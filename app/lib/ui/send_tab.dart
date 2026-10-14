import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/app_controller.dart';
import '../platform/media.dart';
import '../platform/paste_button.dart';
import '../platform/share_intake.dart';
import '../transfer/block_transport.dart';
import '../transfer/payload_io.dart';
import '../transfer/send_service.dart';
import 'app.dart';
import 'format.dart';
import 'widgets.dart';

class SendTab extends StatefulWidget {
  const SendTab({super.key, required this.controller, required this.share});

  final AppController controller;
  final ShareIntake share;

  @override
  State<SendTab> createState() => _SendTabState();
}

class _SendTabState extends State<SendTab> {
  final _text = TextEditingController();
  final List<SourceEntry> _files = [];
  String _expiresIn = '24h';
  bool _deleteAfterPickup = false;
  bool _busy = false;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    widget.share.pending.addListener(_onShare);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onShare());
  }

  @override
  void dispose() {
    widget.share.pending.removeListener(_onShare);
    _text.dispose();
    super.dispose();
  }

  Future<void> _onShare() async {
    final payload = widget.share.take();
    if (payload == null) return;
    final entries = <SourceEntry>[];
    for (final path in payload.files) {
      if (await File(path).exists()) entries.add(await SourceEntry.fromFile(path));
    }
    if (!mounted) return;
    setState(() {
      if (entries.isNotEmpty) {
        _files
          ..clear()
          ..addAll(entries);
      } else if (payload.text != null) {
        _files.clear();
        _text.text = payload.text!;
      }
    });
    showMessage(context, '已载入分享内容，确认后点击发送');
  }

  Future<void> _pickImages() async {
    try {
      final images = await ImagePicker().pickMultiImage(requestFullMetadata: false);
      final entries = [for (final image in images) await SourceEntry.fromFile(image.path, name: image.name)];
      if (entries.isNotEmpty) setState(() => _files.addAll(entries));
    } catch (error) {
      if (mounted) showMessage(context, '无法选择图片：$error');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final picked = await FilePicker.pickFiles();
      final entries = <SourceEntry>[];
      for (final file in picked) {
        final path = file.path ?? await _copyToTemp(file);
        entries.add(await SourceEntry.fromFile(path, name: file.name));
      }
      if (entries.isNotEmpty) setState(() => _files.addAll(entries));
    } catch (error) {
      if (mounted) showMessage(context, '无法选择文件：$error');
    }
  }

  Future<String> _copyToTemp(PlatformFile file) async {
    final dir = Directory(p.join(controller.workDir.path, 'picked', '${DateTime.now().microsecondsSinceEpoch}'));
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, safeFileName(file.name, 0)));
    final sink = target.openWrite();
    await sink.addStream(file.readAsByteStream());
    await sink.close();
    return target.path;
  }

  Future<SendDraft> _draft({String? text, List<SourceEntry>? files}) async {
    final entries = files ?? _files;
    if (entries.isEmpty) {
      final value = text ?? _text.text;
      if (value.isEmpty) throw const TransferException('请输入文本或选择图片、文件');
      return SendDraft(
        kind: 'text',
        entries: [SourceEntry.bytes(utf8.encode(value), name: '', mime: 'text/plain; charset=utf-8')],
        preview: value.length > 200 ? value.substring(0, 200) : value,
        expiresIn: _expiresIn,
        deleteAfterPickup: _deleteAfterPickup,
      );
    }
    final allImages = entries.every((e) => e.mime.startsWith('image/'));
    return SendDraft(
      kind: allImages ? 'image' : 'files',
      entries: entries,
      thumbnail: allImages ? await makeThumbnail(entries.first.path!) : null,
      expiresIn: _expiresIn,
      deleteAfterPickup: _deleteAfterPickup,
    );
  }

  Future<void> _send({String? text, List<SourceEntry>? files}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final draft = await _draft(text: text, files: files);
      final total = draft.entries.fold(0, (sum, e) => sum + e.size);
      if (total > maxPlaintextBytes) throw const TransferException('内容超过 100 MB 上限');
      final title = draft.kind == 'text' ? (draft.preview ?? '文本') : '${draft.entries.length} 个${draft.kind == 'image' ? '图片' : '文件'}';
      final future = controller.send(draft, title: title);
      if (files == null && text == null) {
        setState(() {
          _files.clear();
          _text.clear();
        });
      }
      setState(() => _busy = false);
      final result = await future;
      if (mounted) await _showResult(result);
    } on TransferCancelled {
      if (mounted) showMessage(context, '已取消发送');
    } catch (error) {
      if (mounted) showMessage(context, '发送失败：$error');
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  void _onPasted(PastedContent content) {
    final imagePath = content.imagePath;
    if (imagePath != null) {
      SourceEntry.fromFile(imagePath, name: '剪贴板图片.png', mime: 'image/png').then((entry) => _send(files: [entry])).whenComplete(() async {
        try {
          await File(imagePath).delete();
        } on FileSystemException {
          // already gone
        }
      });
    } else if (content.text?.isNotEmpty == true) {
      _send(text: content.text);
    } else {
      showMessage(context, '剪贴板中没有可发送的文本或图片');
    }
  }

  Future<void> _showResult(SendResult result) => showShadDialog<void>(
    context: context,
    builder: (context) {
      final theme = ShadTheme.of(context);
      return ShadDialog(
        title: const Text('发送成功'),
        actions: [
          ShadButton.outline(
            onPressed: () => copyText(context, result.pickupCode, done: '取件码已复制'),
            leading: const Icon(LucideIcons.copy, size: 16),
            child: const Text('复制取件码'),
          ),
          ShadButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
        ],
        child: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              Text('取件码', style: theme.mutedText),
              const SizedBox(height: 8),
              SelectableText(
                result.pickupCode,
                style: theme.textTheme.h1.copyWith(
                  letterSpacing: 6,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.foreground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 8),
              Text('${formatTime(result.expiresAt)} 过期', style: theme.mutedText.copyWith(fontSize: 13)),
            ],
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final outgoing = controller.transfers.values.where((t) => t.outgoing).toList();
    final failedJobs = controller.outbox.values.where((job) => !controller.transfers.containsKey('send-${job.itemId}')).toList();
    final total = _files.fold(0, (sum, e) => sum + e.size);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SectionTitle('一键发送剪贴板', trailing: PasteButton(onPasted: _onPasted)),
        const ShadSeparator.horizontal(margin: EdgeInsets.symmetric(vertical: 12)),
        if (_files.isEmpty)
          ShadTextarea(controller: _text, minHeight: 120, maxHeight: 260, placeholder: const Text('输入要发送的文本'))
        else
          ShadCard(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, entry) in _files.indexed)
                  ListRow(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    leading: IconTile(entry.mime.startsWith('image/') ? LucideIcons.image : LucideIcons.file, size: 36),
                    title: entry.name,
                    subtitle: Text(formatBytes(entry.size)),
                    trailing: ShadIconButton.ghost(
                      icon: const Icon(LucideIcons.x, size: 16),
                      onPressed: () => setState(() => _files.removeAt(index)),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    '合计 ${formatBytes(total)}${total > maxPlaintextBytes ? '（超过 100 MB 上限）' : ''}',
                    style: theme.mutedText.copyWith(fontSize: 13, color: total > maxPlaintextBytes ? theme.colorScheme.destructive : null),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ShadButton.outline(onPressed: _pickImages, leading: const Icon(LucideIcons.images, size: 16), child: const Text('图片')),
            ShadButton.outline(onPressed: _pickFiles, leading: const Icon(LucideIcons.paperclip, size: 16), child: const Text('文件')),
            if (_files.isNotEmpty) ShadButton.ghost(onPressed: () => setState(_files.clear), child: const Text('改为发送文本')),
          ],
        ),
        const SizedBox(height: 20),
        Text('有效期', style: theme.textTheme.small),
        const SizedBox(height: 8),
        ShadTabs<String>(
          value: _expiresIn,
          onChanged: (value) => setState(() => _expiresIn = value),
          tabs: [for (final e in expiryOptions.entries) ShadTab(value: e.key, child: Text(e.value))],
        ),
        const SizedBox(height: 16),
        ShadSwitch(
          value: _deleteAfterPickup,
          onChanged: (value) => setState(() => _deleteAfterPickup = value),
          label: const Text('取件后即删'),
          sublabel: const Text('其他设备首次取件完成后自动删除'),
        ),
        const SizedBox(height: 20),
        ShadButton(
          size: ShadButtonSize.lg,
          onPressed: _busy ? null : () => _send(),
          leading: const Icon(LucideIcons.send, size: 18),
          child: Text(_busy ? '正在准备…' : '发送'),
        ),
        for (final transfer in outgoing) _TransferCard(controller: controller, transfer: transfer),
        if (failedJobs.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionTitle('未完成的发送'),
          ShadCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, job) in failedJobs.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  ListRow(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    title: job.summary,
                    subtitle: Text('取件码 ${job.pickupCode} · ${formatBytes(job.plaintextSize)}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ShadButton.ghost(
                          size: ShadButtonSize.sm,
                          onPressed: () async {
                            try {
                              final result = await controller.resumeSend(job);
                              if (context.mounted) await _showResult(result);
                            } on TransferCancelled {
                              // user cancelled
                            } catch (error) {
                              if (context.mounted) showMessage(context, '发送失败：$error');
                            }
                          },
                          child: const Text('继续'),
                        ),
                        ShadButton.ghost(size: ShadButtonSize.sm, onPressed: () => controller.discardSend(job), child: const Text('放弃')),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({required this.controller, required this.transfer});

  final AppController controller;
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final progress = transfer.progress;
    final failed = transfer.error != null;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ShadCard(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(transfer.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.small),
                  const SizedBox(height: 12),
                  if (failed)
                    Text('发送失败：${transfer.error}', style: theme.mutedText.copyWith(color: theme.colorScheme.destructive))
                  else ...[
                    ShadProgress(value: progress?.fraction),
                    const SizedBox(height: 8),
                    Text(
                      progress == null
                          ? '正在准备'
                          : '${progress.label}${progress.total > 0 ? ' ${formatBytes(progress.done)} / ${formatBytes(progress.total)}' : ''}',
                      style: theme.mutedText.copyWith(fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: failed
                  ? ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: () => controller.dismissTransfer(transfer.id),
                      child: const Text('关闭'),
                    )
                  : ShadButton.ghost(size: ShadButtonSize.sm, onPressed: transfer.cancel.cancel, child: const Text('取消')),
            ),
          ],
        ),
      ),
    );
  }
}
