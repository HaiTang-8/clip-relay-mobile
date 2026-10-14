import 'dart:convert';
import 'dart:typed_data';

const int _maxSafeInteger = 9007199254740991;
final RegExp _base64UrlPattern = RegExp(r'^[A-Za-z0-9_-]*$');

class RelayCryptoException implements Exception {
  RelayCryptoException(this.message);

  final String message;

  @override
  String toString() => 'RelayCryptoException: $message';
}

String base64UrlEncodeNoPad(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List base64UrlDecodeNoPad(String value) {
  if (!_base64UrlPattern.hasMatch(value) || value.length % 4 == 1) {
    throw RelayCryptoException('Invalid base64url value');
  }
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    throw RelayCryptoException('Invalid base64url value');
  }
}

String hexEncode(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List concatBytes(List<List<int>> parts) {
  final out = Uint8List(parts.fold(0, (sum, part) => sum + part.length));
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}

bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(buffer, value);
  return buffer.toString();
}

void _writeCanonical(StringBuffer out, Object? value) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is num) {
    if (value is double && value != value.truncateToDouble() || value.abs() > _maxSafeInteger) {
      throw RelayCryptoException('Canonical JSON only supports safe integers');
    }
    out.write(value.toInt());
  } else if (value is String) {
    _writeString(out, value);
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _writeCanonical(out, value[i]);
    }
    out.write(']');
  } else if (value is Map) {
    final keys = value.keys.map((key) => key as String).toList()..sort();
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(',');
      _writeString(out, keys[i]);
      out.write(':');
      _writeCanonical(out, value[keys[i]]);
    }
    out.write('}');
  } else {
    throw RelayCryptoException('Canonical JSON value is not serializable');
  }
}

const Map<int, String> _shortEscapes = {
  0x08: r'\b',
  0x09: r'\t',
  0x0a: r'\n',
  0x0c: r'\f',
  0x0d: r'\r',
  0x22: r'\"',
  0x5c: r'\\',
};

void _writeString(StringBuffer out, String value) {
  out.write('"');
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    final short = _shortEscapes[unit];
    if (short != null) {
      out.write(short);
    } else if (unit < 0x20) {
      _writeUnicodeEscape(out, unit);
    } else if (unit >= 0xd800 && unit <= 0xdbff) {
      final next = i + 1 < value.length ? value.codeUnitAt(i + 1) : 0;
      if (next >= 0xdc00 && next <= 0xdfff) {
        out.writeCharCode(unit);
        out.writeCharCode(next);
        i++;
      } else {
        _writeUnicodeEscape(out, unit);
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      _writeUnicodeEscape(out, unit);
    } else {
      out.writeCharCode(unit);
    }
  }
  out.write('"');
}

void _writeUnicodeEscape(StringBuffer out, int unit) {
  out.write(r'\u');
  out.write(unit.toRadixString(16).padLeft(4, '0'));
}
