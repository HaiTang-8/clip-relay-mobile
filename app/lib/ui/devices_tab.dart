import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/app_controller.dart';
import '../core/binding.dart';
import 'app.dart';
import 'format.dart';
import 'widgets.dart';

class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key, required this.controller});

  final AppController controller;

  Future<void> _unbind(BuildContext context) async {
    final ok = await confirm(
      context,
      title: '解除本机绑定',
      description: '将删除本机的密钥和授权凭证，并清除未完成的传输。\n解除后请在电脑端设备列表中释放本机，以腾出设备名额。',
      action: '解除绑定',
      destructive: true,
    );
    if (ok) await controller.unbind();
  }

  Future<void> _trust(BuildContext context, TrustedDevice device) async {
    final ok = await confirm(
      context,
      title: '设备指纹已变化',
      description:
          '「${device.device.displayName}」的公钥指纹已变为：\n\n${formatFpr(device.device.fingerprint)}\n\n'
          '请在该设备上核对指纹一致后再信任，否则可能有人冒充该设备。',
      action: '信任新指纹',
    );
    if (ok) await controller.trustDevice(device.device);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final me = controller.credentials;
    if (me == null) return const SizedBox.shrink();
    final entitlement = me.entitlement;
    final others = controller.devices.where((d) => d.device.deviceId != me.deviceId).toList();
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionTitle('本机'),
          ShadCard(
            padding: EdgeInsets.zero,
            child: ListRow(
              leading: const IconTile(LucideIcons.smartphone),
              title: me.deviceName,
              subtitle: Text('指纹 ${formatFpr(me.fingerprint)}\n${me.boundVia == 'qr' ? '通过电脑扫码绑定' : '通过授权码绑定，请在电脑端核对指纹'}'),
              onLongPress: () => copyText(context, me.fingerprint, done: '指纹已复制'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '订阅状态：${entitlement['status'] == 'active' ? '有效' : '${entitlement['status']}'}'
            '${me.expiresAt != null ? ' · 到期 ${formatTime(me.expiresAt!)}' : ''}'
            '${entitlement['deviceLimit'] != null ? ' · 设备 ${entitlement['deviceCount']}/${entitlement['deviceLimit']}' : ''}',
            style: theme.mutedText.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 24),
          const SectionTitle('订阅内设备'),
          if (others.isEmpty)
            ShadCard(
              child: Center(child: Text('暂无其他设备', style: theme.mutedText)),
            )
          else
            ShadCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final (i, device) in others.indexed) ...[
                    if (i > 0) const Divider(height: 1),
                    _DeviceRow(device: device, onTrust: () => _trust(context, device)),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text('释放设备请在电脑端或管理后台操作。', style: theme.mutedText.copyWith(fontSize: 13)),
          const SizedBox(height: 32),
          ShadButton.outline(
            onPressed: () => _unbind(context),
            foregroundColor: theme.colorScheme.destructive,
            hoverForegroundColor: theme.colorScheme.destructive,
            leading: const Icon(LucideIcons.unlink, size: 16),
            child: const Text('解除本机绑定'),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.onTrust});

  final TrustedDevice device;
  final VoidCallback onTrust;

  @override
  Widget build(BuildContext context) {
    final d = device.device;
    final badge = switch (device.trust) {
      TrustState.verified => const ShadBadge(child: Text('已校验')),
      TrustState.firstUse => const ShadBadge.secondary(child: Text('首次信任')),
      TrustState.changed => ShadBadge.destructive(onPressed: onTrust, child: const Text('指纹已变化')),
      TrustState.noKeys => const ShadBadge.outline(child: Text('未启用互传')),
    };
    return ListRow(
      leading: IconTile(d.isMobile ? LucideIcons.smartphone : LucideIcons.laptop),
      title: d.displayName,
      subtitle: Text('${d.platformLabel}\n指纹 ${formatFpr(d.fingerprint)}'),
      trailing: badge,
      onTap: device.trust == TrustState.changed ? onTrust : null,
      onLongPress: d.fingerprint == null ? null : () => copyText(context, d.fingerprint!, done: '指纹已复制'),
    );
  }
}
