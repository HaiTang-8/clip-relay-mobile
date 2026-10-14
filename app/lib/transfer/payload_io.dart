import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:path/path.dart' as p;

import '../core/models.dart';

const int maxPlaintextBytes = 100 * 1024 * 1024;

class SourceEntry {
  SourceEntry.file(String this.path, {required this.name, required this.mime, required this.size}) : bytes = null;

  SourceEntry.bytes(Uint8List this.bytes, {required this.name, required this.mime})
      : path = null,
        size = bytes.length;

  static Future<SourceEntry> fromFile(String path, {String? name, String? mime}) async {
    final fileName = name ?? p.basename(path);
    return SourceEntry.file(path, name: fileName, mime: mime ?? mimeOf(fileName), size: await File(path).length());
  }

  final String? path;
  final Uint8List? bytes;
  final String name;
  final String mime;
  final int size;

  Stream<List<int>> open() => bytes != null ? Stream.value(bytes!) : File(path!).openRead();
}

const _mimeTypes = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
  '.bmp': 'image/bmp',
  '.txt': 'text/plain',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.json': 'application/json',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

String mimeOf(String name) => _mimeTypes[p.extension(name).toLowerCase()] ?? 'application/octet-stream';

Future<String> sha256Hex(Stream<List<int>> input, {void Function(int bytes)? onBytes}) async {
  final output = _DigestSink();
  final input0 = hash.sha256.startChunkedConversion(output);
  await for (final chunk in input) {
    input0.add(chunk);
    onBytes?.call(chunk.length);
  }
  input0.close();
  return output.value.toString();
}

class _DigestSink implements Sink<hash.Digest> {
  late hash.Digest value;

  @override
  void add(hash.Digest data) => value = data;

  @override
  void close() {}
}

Stream<List<int>> concatSources(List<SourceEntry> entries) async* {
  for (final entry in entries) {
    yield* entry.open();
  }
}

class BlockFileWriter {
  BlockFileWriter(this.directory, this.blockSize);

  final Directory directory;
  final int blockSize;
  final List<File> files = [];
  RandomAccessFile? _current;
  int _currentSize = 0;

  static File blockFile(Directory directory, int index) => File(p.join(directory.path, '$index.blk'));

  Future<void> add(List<int> data) async {
    var offset = 0;
    while (offset < data.length) {
      if (_current == null || _currentSize == blockSize) {
        await _current?.close();
        final file = blockFile(directory, files.length);
        files.add(file);
        _current = await file.open(mode: FileMode.write);
        _currentSize = 0;
      }
      final take = (blockSize - _currentSize).clamp(0, data.length - offset);
      await _current!.writeFrom(data, offset, offset + take);
      _currentSize += take;
      offset += take;
    }
  }

  Future<void> close() async {
    await _current?.close();
    _current = null;
  }
}

class ReceivedFile {
  const ReceivedFile({required this.path, required this.name, required this.mime, required this.size});

  final String path;
  final String name;
  final String mime;
  final int size;

  bool get isImage => mime.startsWith('image/');
}

String _truncateUtf8(String value, int maxBytes) {
  final out = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    bytes += rune < 0x80 ? 1 : rune < 0x800 ? 2 : rune < 0x10000 ? 3 : 4;
    if (bytes > maxBytes) break;
    out.writeCharCode(rune);
  }
  return out.toString();
}

String safeFileName(String name, int index) {
  var base = p.basename(name.replaceAll('\\', '/')).replaceAll(RegExp(r'[\x00-\x1f\x7f:*?"<>|]'), '_').trim();
  if (utf8.encode(base).length > 200) {
    final ext = p.extension(base);
    final keep = ext.length <= 16 ? ext : '';
    base = '${_truncateUtf8(base.substring(0, base.length - keep.length), 200 - utf8.encode(keep).length).trim()}$keep';
  }
  return base.replaceAll('.', '').trim().isEmpty ? 'file-${index + 1}' : base;
}

class EntrySink {
  EntrySink(this.manifest, {this.directory});

  final Manifest manifest;
  final Directory? directory;
  final List<ReceivedFile> files = [];
  final BytesBuilder _text = BytesBuilder(copy: false);
  final Set<String> _names = {};
  int _index = -1;
  int _remaining = 0;
  int _received = 0;
  RandomAccessFile? _file;
  ByteConversionSink? _digest;
  _DigestSink? _digestOut;

  bool get _isText => manifest.kind == 'text';

  Future<void> _openNext() async {
    _index++;
    final entry = manifest.entries[_index];
    _remaining = entry.size;
    _digestOut = _DigestSink();
    _digest = hash.sha256.startChunkedConversion(_digestOut!);
    if (_isText) return;
    var name = safeFileName(entry.name, _index);
    final stem = p.basenameWithoutExtension(name), ext = p.extension(name);
    for (var n = 2; !_names.add(name.toLowerCase()); n++) {
      name = '$stem ($n)$ext';
    }
    final path = p.join(directory!.path, name);
    files.add(ReceivedFile(path: path, name: name, mime: entry.mime, size: entry.size));
    _file = await File(path).open(mode: FileMode.write);
  }

  Future<void> _finishEntry() async {
    _digest!.close();
    await _file?.close();
    _file = null;
    if (_digestOut!.value.toString() != manifest.entries[_index].sha256) {
      throw const FormatException('内容校验失败（SHA-256 不一致）');
    }
  }

  Future<void> _skipEmpty() async {
    while (_remaining == 0 && _index + 1 < manifest.entries.length) {
      await _openNext();
      if (_remaining == 0) await _finishEntry();
    }
  }

  Future<void> add(List<int> data) async {
    var offset = 0;
    while (offset < data.length) {
      if (_remaining == 0) {
        await _skipEmpty();
        if (_remaining == 0) throw const FormatException('解密内容超出声明大小');
      }
      final take = (data.length - offset).clamp(0, _remaining);
      final slice = Uint8List.sublistView(data is Uint8List ? data : Uint8List.fromList(data), offset, offset + take);
      _digest!.add(slice);
      if (_isText) {
        _text.add(Uint8List.fromList(slice));
      } else {
        await _file!.writeFrom(slice);
      }
      _received += take;
      _remaining -= take;
      offset += take;
      if (_remaining == 0) await _finishEntry();
    }
  }

  Future<void> close() async {
    await _skipEmpty();
    if (_remaining != 0 || _index + 1 != manifest.entries.length || _received != manifest.entries.fold(0, (s, e) => s + e.size)) {
      await _file?.close();
      throw const FormatException('解密内容不完整');
    }
  }

  Future<void> discard() async {
    await _file?.close();
    _file = null;
    for (final file in files) {
      final f = File(file.path);
      if (await f.exists()) await f.delete();
    }
  }

  String get text => utf8.decode(_text.takeBytes(), allowMalformed: true);
}
