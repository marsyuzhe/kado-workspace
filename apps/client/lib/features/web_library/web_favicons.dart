import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/storage/data_mutation_gate.dart';
import '../../core/storage/owned_file_store.dart';
import '../utilities/bookmark_metadata.dart';
import 'web_icons.dart';
import 'web_models.dart';

/// 仅主动读取网站自身的favicon；缓存不是用户图标附件，恢复后缺失即回退。
class WebFaviconService {
  WebFaviconService(this.store, this.files, {BookmarkMetadataService? network})
    : network = network ?? BookmarkMetadataService();
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  final BookmarkMetadataService network;
  static const limit = 32 * 1024 * 1024;
  static bool validKey(String key) =>
      RegExp(r'^[0-9a-f]{64}\.png$').hasMatch(key);
  static File cacheFile(OwnedFileStore owned, String key) {
    if (!validKey(key)) throw const ToolFailure('无效图标缓存引用。');
    return File(p.join(owned.root.path, 'cache', 'web_favicons', key));
  }

  Future<Directory> _directory(OwnedFileStore owned) async {
    final root = await owned.root.resolveSymbolicLinks();
    var path = root;
    for (final name in ['cache', 'web_favicons']) {
      path = p.join(path, name);
      final directory = Directory(path);
      if (!await directory.exists()) await directory.create();
      if (!p.equals(await directory.resolveSymbolicLinks(), path)) {
        throw const ToolFailure('缓存目录包含重定向，未写入。');
      }
    }
    final cache = Directory(path);
    return cache;
  }

  Future<void> fetch(WebsiteBookmark site) async {
    final address = Uri.parse(normalizeWebsiteUrl(site.url));
    final uri = Uri(
      scheme: address.scheme,
      host: address.host,
      port: address.hasPort ? address.port : null,
      path: '/favicon.ico',
    );
    final bytes = await network.readPublic(
      uri.toString(),
      sameOriginOnly: true,
    );
    final png = await WebIconService(store, files).prepare(bytes),
        owned = await files();
    await DataMutationGate.shared.run(() async {
      final directory = await _directory(owned),
          key =
              '${sha256.convert([...utf8.encode(uri.toString()), ...png])}.png',
          file = cacheFile(owned, key);
      var size = 0;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && validKey(p.basename(entry.path))) {
          size += await entry.length();
        }
      }
      if (size + png.length > limit) {
        throw const ToolFailure('图标缓存达到32MiB，请在导航菜单清理缓存后重试。');
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const ToolFailure('图标缓存不能是链接。');
      }
      var created = false;
      try {
        if (await file.exists()) {
          if (await file.length() > 256 * 1024 ||
              '${sha256.convert([...utf8.encode(uri.toString()), ...await file.readAsBytes()])}.png' !=
                  key) {
            await file.delete();
          }
        }
        if (!await file.exists()) {
          await file.create(exclusive: true);
          created = true;
          await file.writeAsBytes(png, flush: true);
        }
        await store.transaction(() async {
          final current = await store.get(site.id);
          if (current?.revision != site.record.revision ||
              current?.kind != 'favorite') {
            throw const RecordConflict();
          }
          await store.save(
            current!.copyWith(
              data: {
                ...current.data,
                'faviconCacheKey': key,
                'faviconUrl': uri.toString(),
              },
            ),
          );
        });
      } catch (_) {
        if (created && await file.exists()) await file.delete();
        rethrow;
      }
    });
  }

  Future<int> clear() => DataMutationGate.shared.run(() async {
    final directory = await _directory(await files());
    var count = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && validKey(p.basename(entry.path))) {
        await entry.delete();
        count++;
      }
    }
    return count;
  });
}
