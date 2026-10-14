import 'dart:io';

import 'package:background_downloader/background_downloader.dart';

import '../core/models.dart';
import 'block_transport.dart';

class BackgroundBlockTransport implements BlockTransport {
  BackgroundBlockTransport({FileDownloader? downloader, this.requireHttps = false}) : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;
  final bool requireHttps;

  Future<void> _run(Task task, CancelToken cancel, Future<TaskStatusUpdate> Function() start, String label) async {
    cancel.throwIfCancelled();
    if (requireHttps && !task.url.startsWith('https://')) throw TransferException('$label失败：存储地址必须使用 HTTPS');
    cancel.onCancel(() => _downloader.cancelTaskWithId(task.taskId));
    final result = await start();
    switch (result.status) {
      case TaskStatus.complete:
        return;
      case TaskStatus.canceled:
        throw const TransferCancelled();
      default:
        if (cancel.isCancelled) throw const TransferCancelled();
        final code = result.responseStatusCode;
        throw TransferException(
          code != null && code >= 300 ? '$label失败（HTTP $code）' : '$label失败：${result.exception?.description ?? result.status.name}',
          statusCode: code,
        );
    }
  }

  void Function(double) _progress(int size, ByteProgress onProgress) => (value) {
        if (value >= 0) onProgress((value * size).round());
      };

  @override
  Future<void> upload(TransferUrl target, File file, {required ByteProgress onProgress, required CancelToken cancel}) async {
    final (base, directory, filename) = await Task.split(file: file);
    final task = UploadTask(
      url: target.url,
      filename: filename,
      directory: directory,
      baseDirectory: base,
      headers: target.headers,
      httpRequestMethod: target.method,
      post: 'binary',
      mimeType: 'application/octet-stream',
      updates: Updates.statusAndProgress,
      retries: 2,
    );
    await _run(task, cancel, () => _downloader.upload(task, onProgress: _progress(target.size, onProgress)), '上传');
  }

  @override
  Future<void> download(TransferUrl source, File file, {required ByteProgress onProgress, required CancelToken cancel}) async {
    final (base, directory, filename) = await Task.split(file: file);
    final task = DownloadTask(
      url: source.url,
      filename: filename,
      directory: directory,
      baseDirectory: base,
      headers: source.headers,
      updates: Updates.statusAndProgress,
      retries: 2,
    );
    await _run(task, cancel, () => _downloader.download(task, onProgress: _progress(source.size, onProgress)), '下载');
  }
}
