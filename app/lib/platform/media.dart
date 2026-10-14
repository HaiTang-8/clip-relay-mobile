import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';

import '../transfer/payload_io.dart';

const int thumbnailMaxBytes = 32 * 1024;

String? thumbnailFromBytes(List<int> bytes) {
  final image = img.decodeImage(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  if (image == null) return null;
  final oriented = img.bakeOrientation(image);
  for (final (edge, quality) in const [(240, 70), (160, 60), (96, 50)]) {
    final scale = edge / (oriented.width > oriented.height ? oriented.width : oriented.height);
    final resized = scale < 1
        ? img.copyResize(oriented, width: (oriented.width * scale).round().clamp(1, edge), height: (oriented.height * scale).round().clamp(1, edge))
        : oriented;
    final jpeg = img.encodeJpg(resized, quality: quality);
    if (jpeg.length <= thumbnailMaxBytes) return base64.encode(jpeg);
  }
  return null;
}

Future<String?> makeThumbnail(String path) async {
  try {
    if (await File(path).length() > 40 * 1024 * 1024) return null;
    return await Isolate.run(() => thumbnailFromBytes(File(path).readAsBytesSync()));
  } catch (_) {
    return null;
  }
}

Future<void> saveImageToPhotos(String path) async {
  if (!await Gal.hasAccess()) await Gal.requestAccess();
  await Gal.putImage(path);
}

Future<bool> saveFileAs(ReceivedFile file) async {
  final uri = await FilePicker.saveFile(fileName: file.name, bytes: await File(file.path).readAsBytes(), mimeType: file.mime);
  return uri != null;
}

Future<void> shareFiles(List<ReceivedFile> files, BuildContext context) async {
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    files: [for (final file in files) XFile(file.path, mimeType: file.mime, name: file.name)],
    sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}
