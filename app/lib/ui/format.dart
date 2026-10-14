import 'package:relay_crypto/relay_crypto.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String _two(int v) => v.toString().padLeft(2, '0');

String formatTime(DateTime time) {
  final t = time.toLocal();
  final now = DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return '今天 $hm';
  return '${t.year == now.year ? '' : '${t.year}年'}${t.month}月${t.day}日 $hm';
}

String formatRemaining(DateTime expiresAt) {
  final left = expiresAt.difference(DateTime.now());
  if (left.isNegative) return '已过期';
  if (left.inDays >= 1) return '${left.inDays} 天后过期';
  if (left.inHours >= 1) return '${left.inHours} 小时后过期';
  return '${left.inMinutes.clamp(1, 59)} 分钟后过期';
}

String formatFpr(String? hex) => hex == null ? '无公钥' : formatFingerprint(hex);

const expiryOptions = {'1h': '1 小时', '24h': '24 小时', '7d': '7 天'};
