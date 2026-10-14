import 'dart:async';
import 'dart:io';

import '../core/models.dart';

class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => '已取消';
}

class TransferException implements Exception {
  const TransferException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void onCancel(void Function() listener) => _cancelled ? listener() : _listeners.add(listener);

  void throwIfCancelled() {
    if (_cancelled) throw const TransferCancelled();
  }
}

typedef ByteProgress = void Function(int bytes);

abstract class BlockTransport {
  Future<void> upload(TransferUrl target, File file, {required ByteProgress onProgress, required CancelToken cancel});

  Future<void> download(TransferUrl source, File file, {required ByteProgress onProgress, required CancelToken cancel});
}

class HttpBlockTransport implements BlockTransport {
  HttpBlockTransport([HttpClient? client]) : _client = client ?? HttpClient();

  final HttpClient _client;

  Future<T> _run<T>(CancelToken cancel, Future<T> Function(void Function(void Function()) onAbort) body) async {
    cancel.throwIfCancelled();
    void Function()? abort;
    cancel.onCancel(() => abort?.call());
    try {
      return await body((fn) => abort = fn);
    } catch (error) {
      if (cancel.isCancelled) throw const TransferCancelled();
      if (error is TransferException) rethrow;
      throw TransferException('网络传输失败：$error');
    }
  }

  @override
  Future<void> upload(TransferUrl target, File file, {required ByteProgress onProgress, required CancelToken cancel}) => _run(cancel, (onAbort) async {
        final request = await _client.openUrl(target.method, Uri.parse(target.url));
        onAbort(() => request.abort(const TransferCancelled()));
        target.headers.forEach(request.headers.set);
        request.contentLength = await file.length();
        var sent = 0;
        await request.addStream(file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress(sent);
          return chunk;
        }));
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode >= 300) {
          throw TransferException('上传失败（HTTP ${response.statusCode}）', statusCode: response.statusCode);
        }
      });

  @override
  Future<void> download(TransferUrl source, File file, {required ByteProgress onProgress, required CancelToken cancel}) => _run(cancel, (onAbort) async {
        final request = await _client.openUrl(source.method, Uri.parse(source.url));
        onAbort(() => request.abort(const TransferCancelled()));
        source.headers.forEach(request.headers.set);
        final response = await request.close();
        if (response.statusCode >= 300) {
          await response.drain<void>();
          throw TransferException('下载失败（HTTP ${response.statusCode}）', statusCode: response.statusCode);
        }
        final partial = File('${file.path}.part');
        final sink = partial.openWrite();
        var received = 0;
        try {
          await sink.addStream(response.map((chunk) {
            received += chunk.length;
            onProgress(received);
            return chunk;
          }));
        } finally {
          await sink.close();
        }
        await partial.rename(file.path);
      });
}
