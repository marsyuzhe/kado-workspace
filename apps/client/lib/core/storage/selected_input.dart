import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../data/tool_record.dart';

/// 只读取用户主动选择的文件，声明大小与实际流大小均有界。
Future<Uint8List> readToolFile(PlatformFile file, int limit) async {
  if ((await file.length() ?? 0) > limit) {
    throw const ToolFailure('文件超过本工具的大小限制。');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.readAsByteStream()) {
    bytes.add(chunk);
    if (bytes.length > limit) throw const ToolFailure('文件超过本工具的大小限制。');
  }
  return bytes.takeBytes();
}
