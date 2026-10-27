import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/storage/owned_file_store.dart';
import '../utilities/image_service.dart';
import 'web_models.dart';

/// 自定义图标属于用户附件，进入全量备份；不是可随意清理的favicon缓存。
class WebIconService {
  WebIconService(this.store, this.files);
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  Future<Uint8List> prepare(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const ToolFailure('自定义图标限5MiB静态PNG/JPEG/WebP。');
    }
    final result = await transformImageAsync(
      bytes,
      const ImageOptions(
        width: 256,
        height: 256,
        maintainAspect: true,
        noUpscale: true,
      ),
    );
    if (result.bytes.length > 256 * 1024) {
      throw const ToolFailure('处理后的图标超过256KiB。');
    }
    return result.bytes;
  }

  Future<WebsiteBookmark> setIcon(WebsiteBookmark site, Uint8List bytes) async {
    final png = await prepare(bytes), owned = await files();
    final path = await owned.write('web_icons', png, extension: 'png');
    try {
      return await store.transaction(() async {
        final current = await store.get(site.id);
        if (current?.kind != 'favorite' ||
            current!.revision != site.record.revision ||
            (current.data['action'] as Map?)?['type'] != 'url') {
          throw const RecordConflict();
        }
        final attachment = await store.create(
          'web_icon',
          '网站自定义图标',
          data: {
            'attachment': path,
            'websiteId': site.id,
            'size': png.length,
            'checksum': sha256.convert(png).toString(),
            'syncAllowed': false,
          },
        );
        return WebsiteBookmark(
          await store.save(
            current.copyWith(
              data: {
                ...current.data,
                'customIconPath': path,
                'customIconId': attachment.id,
                'userModified': true,
              },
            ),
          ),
        );
      });
    } catch (_) {
      await owned.remove(path);
      rethrow;
    }
  }

  /// 旧图标仍由附件记录保留到用户清理备份，避免任务/回收站引用悬空。
  Future<void> clearIcon(WebsiteBookmark site) async =>
      store.transaction(() async {
        final row = await store.get(site.id);
        if (row?.kind != 'favorite' ||
            row!.revision != site.record.revision ||
            (row.data['action'] as Map?)?['type'] != 'url') {
          throw const RecordConflict();
        }
        await store.save(
          row.copyWith(
            data: {
              ...row.data,
              'customIconPath': '',
              'customIconId': '',
              'userModified': true,
            },
          ),
        );
      });
}
