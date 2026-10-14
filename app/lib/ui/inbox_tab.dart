import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/app_controller.dart';
import '../platform/media.dart';
import '../transfer/block_transport.dart';
import '../transfer/receive_service.dart';
import 'app.dart';
import 'format.dart';
import 'widgets.dart';

Uint8List? decodeThumbnail(String? value) {
  if (value == null) return null;
  try {
    return base64.decode(base64.normalize(value.replaceAll('-', '+').replaceAll('_', '/')));
  } on FormatException {
    return null;
  }
}

class InboxTab extends StatefulWidget {
  const InboxTab({super.key, required this.controller});

  final AppController controller;

  @override
  State<InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends State<InboxTab> {
  final _code = TextEditingController();
  bool _finding = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      showMessage(context, '请输入 6 位取件码');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _finding = true);
    try {
      final view = await widget.controller.findByCode(code);
      _code.clear();
      if (mounted) await showItemSheet(context, widget.controller, view.item.itemId);
    } catch (error) {
      if (mounted) showMessage(context, error);
    } finally {
      if (mounted) setState(() => _finding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final controller = widget.controller;
    final items = controller.items;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: ShadInput(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _find(),
                  placeholder: const Text('输入 6 位取件码'),
                  leading: Icon(LucideIcons.hash, size: 16, color: theme.colorScheme.mutedForeground),
                ),
              ),
              const SizedBox(width: 8),
              ShadButton(onPressed: _finding ? null : _find, child: Text(_finding ? '查找中' : '取件')),
            ],
          ),
          const SizedBox(height: 24),
          SectionTitle(
            '待取件',
            trailing: controller.refreshing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
          ),
          if (items.isEmpty)
            ShadCard(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(controller.refreshing ? '正在加载…' : '暂无取件\n下拉可刷新', textAlign: TextAlign.center, style: theme.mutedText),
              ),
            )
          else
            ShadCard(
              padding: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (i, view) in items.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    _ItemTile(controller: controller, view: view),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String itemTitle(ItemView view) {
  final manifest = view.opened?.manifest;
  if (manifest == null) return '取件 ${view.item.pickupCode}';
  if (manifest.kind == 'text') {
    final text = (manifest.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? '文本' : text;
  }
  final names = manifest.entries.map((e) => e.name.isEmpty ? '未命名' : e.name).toList();
  return names.length == 1 ? names.first : '${names.first} 等 ${names.length} 个${manifest.kind == 'image' ? '图片' : '文件'}';
}

IconData itemIcon(ItemView view) => switch (view.opened?.manifest.kind) {
  'text' => LucideIcons.fileText,
  'image' => LucideIcons.image,
  'files' => LucideIcons.file,
  _ => LucideIcons.lock,
};

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.controller, required this.view});

  final AppController controller;
  final ItemView view;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final item = view.item;
    final thumb = decodeThumbnail(view.opened?.manifest.thumbnail);
    final transfer = controller.transfers['recv-${item.itemId}'];
    final picked = controller.picked.contains(item.itemId);
    final subtitle = <String>[
      controller.deviceName(item.senderDeviceId),
      formatBytes(item.plaintextSize),
      formatRemaining(item.expiresAt),
      if (item.deleteAfterPickup) '取件后即删',
      if (picked) '已取件',
    ].join(' · ');
    return ListRow(
      leading: thumb != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(thumb, width: 40, height: 40, fit: BoxFit.cover),
            )
          : IconTile(itemIcon(view)),
      title: itemTitle(view),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (view.error != null)
            Text('${view.error}', style: TextStyle(color: theme.colorScheme.destructive))
          else if (transfer != null && transfer.error == null) ...[
            const SizedBox(height: 6),
            ShadProgress(value: transfer.progress?.fraction, minHeight: 4),
          ],
        ],
      ),
      trailing: Text(item.pickupCode, style: theme.textTheme.small.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      onTap: () => showItemSheet(context, controller, item.itemId),
    );
  }
}

Future<void> showItemSheet(BuildContext context, AppController controller, String itemId) => showShadSheet<void>(
  context: context,
  side: ShadSheetSide.bottom,
  builder: (context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final view = controller.items.where((v) => v.item.itemId == itemId).firstOrNull;
      if (view == null) {
        return const ShadSheet(
          child: SizedBox(height: 120, child: Center(child: Text('取件已不存在'))),
        );
      }
      return _ItemSheet(controller: controller, view: view);
    },
  ),
);

class _ItemSheet extends StatelessWidget {
  const _ItemSheet({required this.controller, required this.view});

  final AppController controller;
  final ItemView view;

  Future<void> _receive(BuildContext context) async {
    try {
      final content = await controller.receive(view);
      if (content.kind == 'text' && context.mounted) await copyText(context, content.text ?? '', done: '已取件并复制到剪贴板');
    } on TransferCancelled {
      // user cancelled
    } catch (error) {
      if (context.mounted) showMessage(context, error);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await confirm(context, title: '删除取件', description: '删除后订阅内所有设备都无法再取件。', action: '删除', destructive: true);
    if (!ok || !context.mounted) return;
    try {
      await controller.deleteItem(view.item);
      if (context.mounted) Navigator.pop(context);
    } catch (error) {
      if (context.mounted) showMessage(context, error);
    }
  }

  Future<void> _guard(BuildContext context, Future<void> Function() action, String done) async {
    try {
      await action();
      if (context.mounted) showMessage(context, done);
    } catch (error) {
      if (context.mounted) showMessage(context, '操作失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final item = view.item;
    final manifest = view.opened?.manifest;
    final transfer = controller.transfers['recv-${item.itemId}'];
    final content = controller.received[item.itemId];
    final thumb = decodeThumbnail(manifest?.thumbnail);
    return ShadSheet(
      title: Text(itemTitle(view), maxLines: 3, overflow: TextOverflow.ellipsis),
      description: Text(
        '取件码 ${item.pickupCode} · ${formatBytes(item.plaintextSize)}\n'
        '来自 ${controller.deviceName(item.senderDeviceId)} · ${formatTime(item.createdAt)} · ${formatRemaining(item.expiresAt)}'
        '${item.deleteAfterPickup ? '\n其他设备取件后即删除' : ''}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (thumb != null) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(thumb, height: 160, fit: BoxFit.contain),
            ),
          ],
          if (manifest != null && manifest.kind != 'text') ...[
            const SizedBox(height: 12),
            for (final entry in manifest.entries)
              Text(
                '• ${entry.name.isEmpty ? '未命名' : entry.name}（${formatBytes(entry.size)}）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.mutedText,
              ),
          ],
          const SizedBox(height: 16),
          if (view.error != null)
            ShadAlert.destructive(icon: const Icon(LucideIcons.circleAlert), description: Text('${view.error}'))
          else if (transfer != null && transfer.error == null) ...[
            Text(transfer.progress?.label ?? '正在准备', style: theme.textTheme.small),
            const SizedBox(height: 8),
            ShadProgress(value: transfer.progress?.fraction),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: ShadButton.ghost(size: ShadButtonSize.sm, onPressed: transfer.cancel.cancel, child: const Text('取消')),
            ),
          ] else if (content == null) ...[
            if (transfer?.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('上次取件失败：${transfer!.error}', style: theme.mutedText.copyWith(color: theme.colorScheme.destructive)),
              ),
            ShadButton(
              size: ShadButtonSize.lg,
              onPressed: () => _receive(context),
              leading: const Icon(LucideIcons.download, size: 18),
              child: Text(transfer?.error != null ? '重试取件' : '取件'),
            ),
          ] else
            _ContentActions(content: content, guard: (action, done) => _guard(context, action, done)),
          const SizedBox(height: 8),
          ShadButton.ghost(
            onPressed: () => _delete(context),
            foregroundColor: theme.colorScheme.destructive,
            hoverForegroundColor: theme.colorScheme.destructive,
            leading: const Icon(LucideIcons.trash2, size: 16),
            child: const Text('删除取件'),
          ),
        ],
      ),
    );
  }
}

class _ContentActions extends StatelessWidget {
  const _ContentActions({required this.content, required this.guard});

  final ReceivedContent content;
  final Future<void> Function(Future<void> Function() action, String done) guard;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    if (content.kind == 'text') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.muted,
              border: Border.all(color: theme.colorScheme.border),
              borderRadius: theme.radius,
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                content.text ?? '',
                style: theme.textTheme.p.copyWith(fontSize: 14, height: 1.5, color: theme.colorScheme.foreground),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ShadButton(
            size: ShadButtonSize.lg,
            onPressed: () => copyText(context, content.text ?? ''),
            leading: const Icon(LucideIcons.copy, size: 18),
            child: const Text('复制文本'),
          ),
        ],
      );
    }
    final images = content.files.where((f) => f.isImage).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (images.isNotEmpty) ...[
          SizedBox(
            height: 120,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final image in images)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(image.path),
                        height: 120,
                        fit: BoxFit.cover,
                        cacheHeight: 360,
                        errorBuilder: (_, _, _) => const Icon(LucideIcons.imageOff),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ShadButton(
            size: ShadButtonSize.lg,
            onPressed: () => guard(() async {
              for (final image in images) {
                await saveImageToPhotos(image.path);
              }
            }, '已存入相册'),
            leading: const Icon(LucideIcons.images, size: 18),
            child: Text(images.length > 1 ? '全部存入相册' : '存入相册'),
          ),
          const SizedBox(height: 8),
        ],
        for (final file in content.files.where((f) => !f.isImage))
          ListRow(
            padding: const EdgeInsets.symmetric(vertical: 8),
            leading: const IconTile(LucideIcons.file, size: 36),
            title: file.name,
            subtitle: Text(formatBytes(file.size)),
            trailing: ShadIconButton.ghost(
              icon: const Icon(LucideIcons.fileDown, size: 18),
              onPressed: () async {
                try {
                  if (await saveFileAs(file) && context.mounted) showMessage(context, '已保存');
                } catch (error) {
                  if (context.mounted) showMessage(context, '保存失败：$error');
                }
              },
            ),
          ),
        Builder(
          builder: (context) => ShadButton.outline(
            size: ShadButtonSize.lg,
            onPressed: () => guard(() => shareFiles(content.files, context), '已打开分享'),
            leading: const Icon(LucideIcons.share, size: 18),
            child: Text(Platform.isIOS ? '分享 / 存储到「文件」' : '分享 / 保存'),
          ),
        ),
      ],
    );
  }
}
