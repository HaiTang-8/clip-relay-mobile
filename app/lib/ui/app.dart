import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../app/app_controller.dart';
import '../platform/share_intake.dart';
import 'bind_page.dart';
import 'home_page.dart';

class DeepLinks with WidgetsBindingObserver {
  final ValueNotifier<String?> bindUri = ValueNotifier(null);

  void attach() {
    WidgetsBinding.instance.addObserver(this);
    final initial = Uri.tryParse(WidgetsBinding.instance.platformDispatcher.defaultRouteName);
    if (initial != null) _accept(initial);
  }

  void _accept(Uri uri) {
    if (uri.scheme == 'cliprelay' && uri.host == 'bind') bindUri.value = uri.toString();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    _accept(routeInformation.uri);
    return true;
  }
}

const _toastTheme = ShadToastTheme(alignment: Alignment.topCenter);

ShadThemeData _theme(Brightness brightness, MediaQueryData media) {
  final dialog = ShadDialogTheme(
    constraints: BoxConstraints(maxWidth: min(512, media.size.width - 32)),
    removeBorderRadiusWhenTiny: false,
    titleTextAlign: TextAlign.start,
    descriptionTextAlign: TextAlign.start,
    useSafeArea: false,
  );
  return ShadThemeData(
    brightness: brightness,
    colorScheme: brightness == Brightness.light ? const ShadBlueColorScheme.light() : const ShadBlueColorScheme.dark(),
    primaryToastTheme: _toastTheme,
    destructiveToastTheme: _toastTheme,
    primaryDialogTheme: dialog,
    alertDialogTheme: dialog,
    sheetTheme: ShadSheetTheme(
      radius: const BorderRadius.vertical(top: Radius.circular(12)),
      removeBorderRadiusWhenTiny: false,
      titleTextAlign: TextAlign.start,
      descriptionTextAlign: TextAlign.start,
      useSafeArea: false,
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + media.padding.bottom),
    ),
    progressTheme: const ShadProgressTheme(minHeight: 8),
  );
}

class ClipRelayApp extends StatelessWidget {
  const ClipRelayApp({super.key, required this.controller, required this.share, required this.links});

  final AppController controller;
  final ShareIntake share;
  final DeepLinks links;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ShadApp.custom(
      theme: _theme(Brightness.light, media),
      darkTheme: _theme(Brightness.dark, media),
      appBuilder: (context) => MaterialApp(
        title: '超级剪切板',
        debugShowCheckedModeBanner: false,
        theme: Theme.of(context),
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => ShadAppBuilder(child: child),
        home: ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            if (!controller.ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
            return controller.bound
                ? HomePage(controller: controller, share: share, links: links)
                : BindPage(controller: controller, links: links);
          },
        ),
      ),
    );
  }
}

void showMessage(BuildContext context, Object message) {
  ShadToaster.of(context).show(ShadToast(description: Text('$message')));
}

Future<void> copyText(BuildContext context, String text, {String done = '已复制'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showMessage(context, done);
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String description,
  required String action,
  bool destructive = false,
}) async {
  final ok = await showShadDialog<bool>(
    context: context,
    builder: (context) => ShadDialog.alert(
      title: Text(title),
      description: Text(description),
      actions: [
        ShadButton.outline(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        destructive
            ? ShadButton.destructive(onPressed: () => Navigator.pop(context, true), child: Text(action))
            : ShadButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}
