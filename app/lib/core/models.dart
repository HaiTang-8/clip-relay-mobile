import 'package:relay_crypto/relay_crypto.dart';

class DeviceCredentials {
  const DeviceCredentials({
    required this.serverUrl,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.keys,
    required this.subscriptionId,
    required this.license,
    required this.boundVia,
    this.issuerDeviceId,
  });

  factory DeviceCredentials.fromJson(Map<String, dynamic> json) => DeviceCredentials(
        serverUrl: json['serverUrl'] as String,
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String,
        platform: json['platform'] as String,
        keys: DeviceKeys.fromJson((json['keys'] as Map).cast<String, dynamic>()),
        subscriptionId: json['subscriptionId'] as String,
        license: (json['license'] as Map).cast<String, dynamic>(),
        boundVia: json['boundVia'] as String,
        issuerDeviceId: json['issuerDeviceId'] as String?,
      );

  final String serverUrl;
  final String deviceId;
  final String deviceName;
  final String platform;
  final DeviceKeys keys;
  final String subscriptionId;
  final Map<String, dynamic> license;
  final String boundVia;
  final String? issuerDeviceId;

  Map<String, dynamic> get entitlement => (license['entitlement'] as Map).cast<String, dynamic>();
  String get fingerprint => keys.fingerprintHex;
  DateTime? get issuedAt => DateTime.tryParse(entitlement['issuedAt'] as String? ?? '');
  DateTime? get offlineUntil => DateTime.tryParse(entitlement['offlineUntil'] as String? ?? '');
  DateTime? get expiresAt => DateTime.tryParse(entitlement['expiresAt'] as String? ?? '');

  bool shouldRefresh(DateTime now) {
    final issued = issuedAt, until = offlineUntil;
    if (issued == null || until == null) return true;
    return now.isAfter(issued.add(until.difference(issued) ~/ 2));
  }

  DeviceCredentials withLicense(Map<String, dynamic> value) => DeviceCredentials(
        serverUrl: serverUrl,
        deviceId: deviceId,
        deviceName: deviceName,
        platform: platform,
        keys: keys,
        subscriptionId: subscriptionId,
        license: value,
        boundVia: boundVia,
        issuerDeviceId: issuerDeviceId,
      );

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'platform': platform,
        'keys': keys.toJson(),
        'subscriptionId': subscriptionId,
        'license': license,
        'boundVia': boundVia,
        'issuerDeviceId': ?issuerDeviceId,
      };
}

String? _fingerprintOf(String x, String ed) {
  try {
    return fingerprint(base64UrlDecodeNoPad(x), base64UrlDecodeNoPad(ed));
  } on RelayCryptoException {
    return null;
  }
}

class RelayDevice {
  const RelayDevice({
    required this.deviceId,
    this.deviceName,
    this.platform,
    this.kind,
    this.x25519PublicKey,
    this.ed25519PublicKey,
    this.fingerprint,
    this.bindProof,
    this.boundByDeviceId,
    this.lastSeenAt,
  });

  factory RelayDevice.fromJson(Map<String, dynamic> json) {
    final x = json['x25519PublicKey'] as String?;
    final ed = json['ed25519PublicKey'] as String?;
    return RelayDevice(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String?,
      platform: json['platform'] as String?,
      kind: json['kind'] as String?,
      x25519PublicKey: x,
      ed25519PublicKey: ed,
      fingerprint: x != null && ed != null ? _fingerprintOf(x, ed) : null,
      bindProof: json['bindProof'] as String?,
      boundByDeviceId: json['boundByDeviceId'] as String?,
      lastSeenAt: DateTime.tryParse(json['lastSeenAt'] as String? ?? ''),
    );
  }

  final String deviceId;
  final String? deviceName;
  final String? platform;
  final String? kind;
  final String? x25519PublicKey;
  final String? ed25519PublicKey;
  final String? fingerprint;
  final String? bindProof;
  final String? boundByDeviceId;
  final DateTime? lastSeenAt;

  bool get hasKeys => fingerprint != null;
  bool get isMobile => kind == 'mobile' || platform == 'ios' || platform == 'android';
  String get displayName => deviceName?.isNotEmpty == true ? deviceName! : deviceId;

  String get platformLabel => switch (platform) {
        'ios' => 'iPhone / iPad',
        'android' => 'Android',
        'darwin' || 'mac' => 'Mac',
        'win32' || 'win' => 'Windows',
        'linux' => 'Linux',
        _ => platform ?? '未知平台',
      };
}

class RelayItem {
  const RelayItem({
    required this.itemId,
    required this.pickupCode,
    required this.senderDeviceId,
    required this.plaintextSize,
    required this.sizeBytes,
    required this.blockCount,
    required this.inline,
    required this.deleteAfterPickup,
    required this.expiresAt,
    required this.createdAt,
    required this.header,
    required this.signature,
    required this.decryptable,
    this.pickedAt,
  });

  factory RelayItem.fromJson(Map<String, dynamic> json) => RelayItem(
        itemId: json['itemId'] as String,
        pickupCode: json['pickupCode'] as String,
        senderDeviceId: json['senderDeviceId'] as String,
        plaintextSize: json['plaintextSize'] as int,
        sizeBytes: json['sizeBytes'] as int,
        blockCount: json['blockCount'] as int? ?? 0,
        inline: json['inline'] as bool? ?? false,
        deleteAfterPickup: json['deleteAfterPickup'] as bool? ?? false,
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        createdAt: DateTime.parse((json['committedAt'] ?? json['createdAt']) as String),
        pickedAt: DateTime.tryParse(json['pickedAt'] as String? ?? ''),
        header: (json['header'] as Map?)?.cast<String, dynamic>(),
        signature: json['signature'] as String?,
        decryptable: json['decryptable'] as bool? ?? true,
      );

  final String itemId;
  final String pickupCode;
  final String senderDeviceId;
  final int plaintextSize;
  final int sizeBytes;
  final int blockCount;
  final bool inline;
  final bool deleteAfterPickup;
  final DateTime expiresAt;
  final DateTime createdAt;
  final DateTime? pickedAt;
  final Map<String, dynamic>? header;
  final String? signature;
  final bool decryptable;

  bool hasRecipient(String deviceId) {
    final recipients = header?['recipients'];
    return recipients is List && recipients.any((stanza) => stanza is Map && stanza['deviceId'] == deviceId);
  }
}

class TransferUrl {
  const TransferUrl({required this.index, required this.url, required this.method, required this.headers, required this.size, this.uploaded = false});

  factory TransferUrl.fromJson(Map<String, dynamic> json) => TransferUrl(
        index: json['index'] as int,
        url: json['url'] as String,
        method: json['method'] as String? ?? 'GET',
        headers: ((json['headers'] as Map?) ?? const {}).map((key, value) => MapEntry('$key', '$value')),
        size: json['size'] as int,
        uploaded: json['uploaded'] as bool? ?? false,
      );

  final int index;
  final String url;
  final String method;
  final Map<String, String> headers;
  final int size;
  final bool uploaded;
}

class CreatedItem {
  const CreatedItem({required this.itemId, required this.pickupCode, required this.inline, required this.blocks, required this.uploadExpiresAt});

  factory CreatedItem.fromJson(Map<String, dynamic> json) => CreatedItem(
        itemId: json['itemId'] as String,
        pickupCode: json['pickupCode'] as String,
        inline: json['inline'] as bool,
        uploadExpiresAt: DateTime.tryParse(json['uploadExpiresAt'] as String? ?? ''),
        blocks: [for (final block in json['blocks'] as List) TransferUrl.fromJson((block as Map).cast<String, dynamic>())],
      );

  final String itemId;
  final String pickupCode;
  final bool inline;
  final DateTime? uploadExpiresAt;
  final List<TransferUrl> blocks;
}

class DownloadInfo {
  const DownloadInfo({required this.inline, required this.blocks, this.inlineCiphertext});

  factory DownloadInfo.fromJson(Map<String, dynamic> json) => DownloadInfo(
        inline: json['inline'] as bool? ?? false,
        inlineCiphertext: json['inlineCiphertext'] as String?,
        blocks: [for (final block in (json['blocks'] as List? ?? const [])) TransferUrl.fromJson((block as Map).cast<String, dynamic>())],
      );

  final bool inline;
  final String? inlineCiphertext;
  final List<TransferUrl> blocks;
}

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

class ManifestEntry {
  const ManifestEntry({required this.name, required this.mime, required this.size, required this.sha256, required this.offset});

  factory ManifestEntry.fromJson(Map<String, dynamic> json) => ManifestEntry(
        name: json['name'] as String? ?? '',
        mime: json['mime'] as String? ?? 'application/octet-stream',
        size: json['size'] as int,
        sha256: (json['sha256'] as String).toLowerCase(),
        offset: json['offset'] as int,
      );

  final String name;
  final String mime;
  final int size;
  final String sha256;
  final int offset;

  bool get isImage => mime.startsWith('image/');

  Map<String, Object> toJson() => {'name': name, 'mime': mime, 'size': size, 'sha256': sha256, 'offset': offset};
}

class Manifest {
  const Manifest({required this.kind, required this.entries, this.text, this.thumbnail, this.createdAt});

  factory Manifest.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final entries = json['entries'];
    if (!const ['text', 'image', 'files'].contains(kind) || entries is! List) {
      throw const FormatException('Invalid manifest');
    }
    return Manifest(
      kind: kind as String,
      entries: [for (final entry in entries) ManifestEntry.fromJson((entry as Map).cast<String, dynamic>())],
      text: json['text'] as String?,
      thumbnail: json['thumbnail'] as String?,
      createdAt: json['createdAt'] as String?,
    );
  }

  final String kind;
  final List<ManifestEntry> entries;
  final String? text;
  final String? thumbnail;
  final String? createdAt;

  void validate(int plaintextSize) {
    var offset = 0;
    for (final entry in entries) {
      if (entry.size < 0 || entry.offset != offset || !_sha256Pattern.hasMatch(entry.sha256)) {
        throw const FormatException('Invalid manifest entry');
      }
      offset += entry.size;
    }
    if (offset != plaintextSize || (kind == 'text' && entries.length != 1)) {
      throw const FormatException('Manifest size mismatch');
    }
  }

  Map<String, Object?> toJson() => {
        'v': relayVersion,
        'kind': kind,
        'entries': [for (final entry in entries) entry.toJson()],
        'text': ?text,
        'thumbnail': ?thumbnail,
        'createdAt': ?createdAt,
      };
}
