import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'config.dart';
import 'store.dart';

int compareVersions(String a, String b) {
  List<int> parts(String v) => v.split(RegExp(r'[-+]')).first.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

class UpdateAsset {
  const UpdateAsset({required this.name, required this.size, required this.sha256, required this.url});

  final String name;
  final int size;
  final String? sha256;
  final Uri url;
}

class UpdateInfo {
  const UpdateInfo({required this.version, required this.notes, required this.asset});

  final String version;
  final String notes;
  final UpdateAsset asset;
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateCancelled implements Exception {}

class UpdateService {
  UpdateService({
    required this.config,
    required this.store,
    required this.workDir,
    required this.platform,
    http.Client? client,
    DateTime Function()? now,
  })  : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  static const ignoredKey = 'update.ignoredVersion';
  static const checkedKey = 'update.lastCheck';
  static const autoInterval = Duration(hours: 24);

  final AppConfig config;
  final KeyValueStore store;
  final Directory workDir;
  final String platform;
  final http.Client _client;
  final DateTime Function() _now;

  String get currentVersion => config.appVersion;

  Uri? get _base {
    if (config.licenseServerUrl.isEmpty) return null;
    try {
      return config.serverUri(config.licenseServerUrl);
    } on ConfigException {
      return null;
    }
  }

  Uri? _endpoint(String path) {
    final base = _base;
    return base == null ? null : Uri.parse('$base/mobile/update/$path');
  }

  Uri? get sourceUrl => _endpoint('source.json');

  Future<UpdateInfo?> check({bool manual = false}) async {
    final endpoint = _endpoint('latest');
    if (endpoint == null) throw const UpdateException('未配置更新服务器');
    if (!manual) {
      final last = DateTime.tryParse(await store.read(checkedKey) ?? '');
      if (last != null && _now().difference(last) < autoInterval) return null;
    }
    final http.Response response;
    try {
      response = await _client.get(endpoint).timeout(const Duration(seconds: 20));
    } on Exception {
      throw const UpdateException('无法连接更新服务器');
    }
    if (response.statusCode != 200) throw UpdateException('检查更新失败（HTTP ${response.statusCode}）');
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const UpdateException('更新信息格式错误');
    }
    await store.write(checkedKey, _now().toIso8601String());
    if (json is! Map) throw const UpdateException('更新信息格式错误');
    final version = json['version'], asset = json[platform], notes = json['notes'];
    if (version is! String || compareVersions(version, currentVersion) <= 0 || asset is! Map) return null;
    if (!manual && await store.read(ignoredKey) == version) return null;
    final url = asset['url'], name = asset['name'], size = asset['size'], sha = asset['sha256'];
    if (url is! String || !url.startsWith('/mobile/update/download/') || name is! String || size is! int) {
      throw const UpdateException('更新信息格式错误');
    }
    return UpdateInfo(
      version: version,
      notes: notes is String ? notes : '',
      asset: UpdateAsset(name: p.basename(name), size: size, sha256: sha is String ? sha.toLowerCase() : null, url: Uri.parse('${_base!}$url')),
    );
  }

  Future<void> ignore(String version) => store.write(ignoredKey, version);

  Future<File> download(UpdateAsset asset, {void Function(double fraction)? onProgress, bool Function()? cancelled}) async {
    if (await workDir.exists()) await workDir.delete(recursive: true);
    await workDir.create(recursive: true);
    final target = File(p.join(workDir.path, asset.name));
    final http.StreamedResponse response;
    try {
      response = await _client.send(http.Request('GET', asset.url)).timeout(const Duration(seconds: 30));
    } on Exception {
      throw const UpdateException('下载失败，请检查网络后重试');
    }
    if (response.statusCode != 200) throw UpdateException('下载失败（HTTP ${response.statusCode}）');
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
        if (cancelled?.call() ?? false) throw UpdateCancelled();
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (asset.size > 0) onProgress?.call((received / asset.size).clamp(0, 1));
      }
    } on UpdateCancelled {
      await sink.close();
      await target.delete();
      rethrow;
    } on Exception {
      await sink.close();
      await target.delete();
      throw const UpdateException('下载中断，请重试');
    }
    await sink.close();
    hasher.close();
    if (received != asset.size || (asset.sha256 != null && digest.value.toString() != asset.sha256)) {
      await target.delete();
      throw const UpdateException('安装包校验失败，请重试');
    }
    return target;
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
