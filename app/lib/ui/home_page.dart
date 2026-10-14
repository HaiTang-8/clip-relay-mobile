import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/app_controller.dart';
import '../platform/share_intake.dart';
import 'app.dart';
import 'devices_tab.dart';
import 'inbox_tab.dart';
import 'send_tab.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller, required this.share, required this.links});

  final AppController controller;
  final ShareIntake share;
  final DeepLinks links;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _tab = 0;
  String? _shownNotice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.share.pending.addListener(_onShare);
    widget.links.bindUri.addListener(_onLink);
    widget.controller.addListener(_onNotice);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onShare();
      _onLink();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.share.pending.removeListener(_onShare);
    widget.links.bindUri.removeListener(_onLink);
    widget.controller.removeListener(_onNotice);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.refresh();
  }

  void _onShare() {
    if (widget.share.pending.value != null && _tab != 1) setState(() => _tab = 1);
  }

  void _onLink() {
    if (widget.links.bindUri.value == null) return;
    widget.links.bindUri.value = null;
    showMessage(context, '本机已绑定。如需重新绑定，请先在「设备」页解除绑定');
  }

  void _onNotice() {
    final notice = widget.controller.notice;
    if (notice != null && notice != _shownNotice && mounted) {
      _shownNotice = notice;
      showMessage(context, notice);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _tab,
          children: [
            InboxTab(controller: controller),
            SendTab(controller: controller, share: widget.share),
            DevicesTab(controller: controller),
          ],
        ),
      ),
      bottomNavigationBar: _BottomBar(
        index: _tab,
        onSelected: (index) => setState(() => _tab = index),
        items: [
          (
            LucideIcons.inbox,
            '取件',
            controller.items.any(
              (v) => !controller.picked.contains(v.item.itemId) && v.item.senderDeviceId != controller.credentials?.deviceId,
            ),
          ),
          (LucideIcons.send, '发送', false),
          (LucideIcons.monitorSmartphone, '设备', false),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onSelected, required this.items});

  final int index;
  final ValueChanged<int> onSelected;
  final List<(IconData, String, bool)> items;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              for (final (i, (icon, label, dot)) in items.indexed)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    child: InkResponse(
                      onTap: () => onSelected(i),
                      highlightShape: BoxShape.rectangle,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Icon(icon, size: 22, color: i == index ? colors.primary : colors.mutedForeground),
                              if (dot)
                                Positioned(
                                  right: -3,
                                  top: -2,
                                  child: Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(color: colors.destructive, shape: BoxShape.circle),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            style: theme.textTheme.small.copyWith(
                              fontSize: 12,
                              color: i == index ? colors.primary : colors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
