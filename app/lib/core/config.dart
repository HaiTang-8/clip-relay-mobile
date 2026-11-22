import 'package:flutter/foundation.dart';

class AppConfig {
  const AppConfig({
    required this.licenseServerUrl,
    required this.publicKey,
    required this.transportPublicKey,
    this.requireTrustRoots = kReleaseMode,
    this.appVersion = '0.0.0',
  });

  factory AppConfig.fromEnvironment({required String appVersion}) => AppConfig(
        licenseServerUrl: const String.fromEnvironment('licenseServerUrl'),
        publicKey: const String.fromEnvironment('publicKey'),
        transportPublicKey: const String.fromEnvironment('transportPublicKey'),
        appVersion: appVersion,
      );

  final String licenseServerUrl;
  final String publicKey;
  final String transportPublicKey;
  final bool requireTrustRoots;
  final String appVersion;

  Uri serverUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !(uri.scheme == 'https' || (!requireTrustRoots && uri.scheme == 'http')) || uri.host.isEmpty) {
      throw const ConfigException('服务器地址无效，正式版本必须使用 HTTPS');
    }
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path.replaceAll(RegExp(r'/+$'), ''));
  }

  void assertTrustRoots() {
    if (requireTrustRoots && (publicKey.isEmpty || transportPublicKey.isEmpty)) {
      throw const ConfigException('应用缺少授权公钥配置，请使用正式构建');
    }
  }
}

class ConfigException implements Exception {
  const ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}
