import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:relay_crypto/relay_crypto.dart';

import '../core/binding.dart';
import '../core/models.dart';
import '../core/relay_api.dart';
import '../core/store.dart';
import '../transfer/block_transport.dart';
import '../transfer/receive_service.dart';
import '../transfer/send_service.dart';

class Transfer {
  Transfer({required this.id, required this.title, required this.outgoing});

  final String id;
  final String title;
  final bool outgoing;
  final CancelToken cancel = CancelToken();
  TransferProgress? progress;
  Object? error;
  bool finished = false;
}

class ItemView {
  const ItemView({required this.item, this.opened, this.error});

  final RelayItem item;
  final OpenedItem? opened;
  final Object? error;

  bool get undecryptable => error is UndecryptableException;
}

class AppController extends ChangeNotifier {
  AppController({required this.binding, required this.store, required this.transport, required this.workDir, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const pickedKey = 'relay.picked';

  final BindingService binding;
  final KeyValueStore store;
  final BlockTransport transport;
  final Directory workDir;
  final DateTime Function() _clock;

  DeviceCredentials? credentials;
  bool ready = false;
  bool refreshing = false;
  String? notice;
  List<TrustedDevice> devices = const [];
  List<ItemView> items = const [];
  Map<String, OutboxJob> outbox = const {};
  final Map<String, Transfer> transfers = {};
  final Map<String, ReceivedContent> received = {};
  Set<String> picked = {};
  final Map<String, OpenedItem> _opened = {};
  RelayApi? _api;
  Future<void>? _refreshing;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get bound => credentials != null;
  RelayApi get api => _api ??= binding.apiFor(credentials!);

  SendService get _sender => SendService(
        api: api,
        me: credentials!,
        transport: transport,
        workDir: workDir,
        store: store,
        recipients: recipients,
      );

  ReceiveService get _receiver => ReceiveService(api: api, me: credentials!, transport: transport, workDir: workDir);

  Future<void> init() async {
    try {
      for (final name in ['received', 'picked']) {
        final dir = Directory('${workDir.path}/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      credentials = await binding.load();
      final pickedJson = await store.readJson(pickedKey);
      if (pickedJson is List) picked = pickedJson.cast<String>().toSet();
    } catch (error) {
      notice = '读取本地数据失败：$error';
    }
    ready = true;
    notifyListeners();
    if (bound) unawaited(refresh());
  }

  void _setCredentials(DeviceCredentials? value) {
    _api?.close();
    _api = null;
    credentials = value;
    devices = const [];
    items = const [];
    outbox = const {};
    _opened.clear();
    received.clear();
  }

  Future<void> bindWithUri(String uri, String deviceName) async {
    _setCredentials(await binding.bindWithUri(uri, deviceName: deviceName));
    notice = null;
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> bindWithLicenseKey(String licenseKey, String deviceName) async {
    _setCredentials(await binding.bindWithLicenseKey(licenseKey, deviceName: deviceName));
    notice = null;
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> unbind({String? reason}) async {
    for (final transfer in transfers.values) {
      transfer.cancel.cancel();
    }
    transfers.clear();
    await binding.reset();
    await store.delete(SendService.outboxKey);
    await store.delete(pickedKey);
    picked = {};
    for (final name in ['outbox', 'inbox', 'received', 'picked']) {
      final dir = Directory('${workDir.path}/$name');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    _setCredentials(null);
    notice = reason;
    notifyListeners();
  }

  Future<bool> _handleAuthError(Object error) async {
    if (error is RelayApiException && (error.code == 'device_inactive' || error.code == 'unauthorized')) {
      await unbind(reason: error.code == 'device_inactive' ? '此设备已被释放，请在电脑端重新扫码绑定' : '设备未授权，请在电脑端重新扫码绑定');
      return true;
    }
    return false;
  }

  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    final me = credentials;
    if (me == null) return;
    refreshing = true;
    notifyListeners();
    try {
      if (me.shouldRefresh(_clock())) {
        try {
          credentials = await binding.refresh(me);
        } on BindException catch (error) {
          notice = error.message;
        }
      }
      await _loadDevices();
      final list = await api.listItems();
      outbox = await _sender.pendingJobs();
      final views = <ItemView>[];
      for (final item in list) {
        views.add(await _view(item));
      }
      final listed = {for (final item in list) item.itemId};
      items = [...views, ...items.where((v) => !listed.contains(v.item.itemId) && received.containsKey(v.item.itemId))];
      _opened.removeWhere((id, _) => !listed.contains(id) && !received.containsKey(id));
      if (notice != null && notice!.startsWith('刷新失败')) notice = null;
    } catch (error) {
      if (!await _handleAuthError(error)) notice = '刷新失败：$error';
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  Future<ItemView> _view(RelayItem item) async {
    final cached = _opened[item.itemId];
    if (cached != null) return ItemView(item: item, opened: cached);
    try {
      final opened = await _receiver.open(item, _senderKey);
      _opened[item.itemId] = opened;
      return ItemView(item: item, opened: opened);
    } catch (error) {
      return ItemView(item: item, error: error);
    }
  }

  Future<List<TrustedDevice>> _loadDevices() async {
    devices = await binding.reconcile(credentials!, await api.listDevices());
    return devices;
  }

  List<int>? _senderKey(String deviceId) {
    final match = devices.where((d) => d.device.deviceId == deviceId && d.usable && d.device.hasKeys).firstOrNull;
    return match == null ? null : base64UrlDecodeNoPad(match.device.ed25519PublicKey!);
  }

  Future<List<RelayDevice>> recipients() async {
    final list = await _loadDevices();
    final usable = [for (final d in list) if (d.usable && d.device.hasKeys) d.device];
    if (!usable.any((d) => d.deviceId == credentials!.deviceId)) {
      throw const TransferException('服务器上的本机公钥与本地不一致，请解除绑定后重新扫码');
    }
    return usable;
  }

  Future<void> trustDevice(RelayDevice device) async {
    await binding.trustCurrentKey(device);
    _opened.clear();
    await refresh();
  }

  String deviceName(String deviceId) {
    if (deviceId == credentials?.deviceId) return '本机';
    return devices.where((d) => d.device.deviceId == deviceId).firstOrNull?.device.displayName ?? '已移除的设备';
  }

  void _progress(Transfer transfer, TransferProgress progress) {
    transfer.progress = progress;
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 120) || progress.done == progress.total) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  Future<T> _run<T>(Transfer transfer, Future<T> Function() body) async {
    transfers[transfer.id] = transfer;
    notifyListeners();
    try {
      final result = await body();
      transfer.finished = true;
      transfers.remove(transfer.id);
      return result;
    } catch (error) {
      transfer.error = error;
      if (error is TransferCancelled) transfers.remove(transfer.id);
      if (await _handleAuthError(error)) transfers.remove(transfer.id);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  void dismissTransfer(String id) {
    transfers.remove(id);
    notifyListeners();
  }

  Future<SendResult> send(SendDraft draft, {required String title}) {
    final transfer = Transfer(id: 'send-${DateTime.now().microsecondsSinceEpoch}', title: title, outgoing: true);
    return _run(transfer, () async {
      final result = await _sender.send(draft, onProgress: (p) => _progress(transfer, p), cancel: transfer.cancel);
      unawaited(refresh());
      return result;
    });
  }

  Future<SendResult> resumeSend(OutboxJob job) {
    final transfer = Transfer(id: 'send-${job.itemId}', title: job.summary, outgoing: true);
    return _run(transfer, () async {
      try {
        final result = await _sender.resume(job, onProgress: (p) => _progress(transfer, p), cancel: transfer.cancel);
        return result;
      } finally {
        unawaited(refresh());
      }
    });
  }

  Future<void> discardSend(OutboxJob job) async {
    await _sender.discard(job.itemId);
    outbox = await _sender.pendingJobs();
    notifyListeners();
  }

  Future<ItemView> findByCode(String code) async {
    final item = await api.findByCode(code.trim());
    final view = await _view(item);
    if (!items.any((v) => v.item.itemId == item.itemId)) items = [view, ...items];
    notifyListeners();
    return view;
  }

  Future<ReceivedContent> receive(ItemView view) async {
    final opened = view.opened;
    if (opened == null) throw view.error ?? const UndecryptableException();
    final item = opened.item;
    final transfer = Transfer(id: 'recv-${item.itemId}', title: item.pickupCode, outgoing: false);
    return _run(transfer, () async {
      final content = await _receiver.download(opened, onProgress: (p) => _progress(transfer, p), cancel: transfer.cancel);
      received[item.itemId] = content;
      picked.add(item.itemId);
      await store.writeJson(pickedKey, picked.toList());
      if (item.senderDeviceId != credentials!.deviceId) {
        try {
          await api.ack(item.itemId);
        } on RelayApiException catch (error) {
          notice = '取件回执发送失败：$error';
        }
      }
      return content;
    });
  }

  Future<void> deleteItem(RelayItem item) async {
    try {
      await api.deleteItem(item.itemId);
    } on RelayApiException catch (error) {
      if (error.code != 'item_not_found' || !received.containsKey(item.itemId)) rethrow;
    }
    items = items.where((v) => v.item.itemId != item.itemId).toList();
    _opened.remove(item.itemId);
    received.remove(item.itemId);
    await _receiver.clearReceived(item.itemId);
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _api?.close();
    super.dispose();
  }
}
