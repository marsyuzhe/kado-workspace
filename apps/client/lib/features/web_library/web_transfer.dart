import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';
import 'package:drift/drift.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/database/app_database.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/storage/owned_file_store.dart';
import 'web_icons.dart';
import 'web_import_reader.dart';
import 'web_models.dart';
import 'web_repository.dart';

Map<String, dynamic> _categoryJson(WebImportCategory c) => {
  'id': c.id,
  'isSystemPreset': c.isSystemPreset,
  'userModified': c.userModified,
  'name': c.input.name,
  'description': c.input.description,
  'parentId': c.input.parentId,
  'iconKey': c.input.iconKey,
  'color': c.input.color,
  'sortOrder': c.input.sortOrder,
  'isHidden': c.input.isHidden,
  'originalPath': c.originalPath,
};
Map<String, dynamic> _siteJson(WebImportSite s) => {
  'id': s.id,
  'title': s.input.title,
  'url': s.input.url,
  'description': s.input.description,
  'categoryId': s.input.categoryId.isEmpty
      ? uncategorizedId
      : s.input.categoryId,
  'tags': s.input.tags,
  'isFavorite': s.input.isFavorite,
  'isPinned': s.input.isPinned,
  'alternateUrl': s.input.alternateUrl,
  'sortOrder': s.order,
  'createdAt': s.createdAt?.toUtc().toIso8601String(),
  'lastVisitedAt': s.lastVisitedAt?.toUtc().toIso8601String(),
  'visitCount': s.visitCount,
  'isSeeded': s.isSeeded,
  'sourceType': s.sourceType,
  'userModified': s.userModified,
  'originalPath': s.originalPath,
  if (s.iconBytes != null)
    'customIcon': {'mime': 'image/png', 'base64': base64.encode(s.iconBytes!)},
};

class _ImportPlan {
  final categories =
      <
        ({WebImportCategory item, String id, String parent, ToolRecord? update})
      >[];
  final sites = <({WebImportSite item, String category, ToolRecord? update})>[];
  final pruneSites = <WebsiteBookmark>[];
  final pruneCategories = <WebsiteCategory>[];
  final categoryNames = <String, String>{};
  int duplicates = 0, conflicts = 0;
}

/// 预览是本地持久记录；确认后重新校验快照，整批事务，不自动重放。
class WebTransferService {
  WebTransferService(this.repository, this.files);
  final WebLibraryRepository repository;
  RecordStore get store => repository.store;
  final Future<OwnedFileStore> Function() files;

  Future<String> _fingerprint() async {
    final rows = await store.db
        .customSelect(
          "SELECT id,revision,deleted_at FROM local_records WHERE kind='website_category' OR (kind='favorite' AND json_extract(data,'\$.action.type')='url') ORDER BY id",
          readsFrom: {store.db.localRecords},
        )
        .get();
    return sha256
        .convert(utf8.encode(jsonEncode(rows.map((r) => r.data).toList())))
        .toString();
  }

  static bool _untouched(WebsiteBookmark s) =>
      s.isSeeded &&
      s.sourceType == 'RECOMMENDED' &&
      !s.record.flag('userModified') &&
      !s.isFavorite &&
      !s.isPinned &&
      s.visitCount == 0 &&
      s.lastVisitedAt == null &&
      s.customIconPath.isEmpty;

  Future<_ImportPlan> _plan(
    WebImportDraft draft,
    String mode,
    bool replaceDefaults,
  ) async {
    if (!{'merge', 'skip', 'folder'}.contains(mode)) {
      throw const ToolFailure('导入方式无效。');
    }
    final plan = _ImportPlan()..duplicates = draft.duplicates;
    final liveCategories = await repository.categories(),
        liveSites = await repository.sites(),
        map = <String, String>{uncategorizedId: uncategorizedId};
    for (final c in liveCategories) {
      plan.categoryNames[c.id] = c.name;
    }
    final incomingIds = {
      ...draft.categories.map((c) => c.id),
      ...draft.sites.map((s) => s.id),
    }.toList();
    final identities = <String, ToolRecord>{};
    for (var start = 0; start < incomingIds.length; start += 400) {
      final rows = await (store.db.select(
        store.db.localRecords,
      )..where((t) => t.id.isIn(incomingIds.skip(start).take(400)))).get();
      for (final row in rows) {
        identities[row.id] = ToolRecord.fromRow(row);
      }
    }
    if (mode == 'folder') {
      final id = newId();
      final folder = WebImportCategory(
        id,
        WebsiteCategoryInput(
          '导入 ${DateTime.now().toLocal().toIso8601String().substring(0, 19).replaceAll('T', ' ')}',
          sortOrder: liveCategories.length,
        ),
      );
      plan.categories.add((item: folder, id: id, parent: '', update: null));
      plan.categoryNames[id] = folder.input.name;
      map[uncategorizedId] = id;
    }
    final ordered = [
      ...draft.categories.where((c) => c.input.parentId.isEmpty),
      ...draft.categories.where((c) => c.input.parentId.isNotEmpty),
    ];
    for (final c in ordered) {
      if (c.id == uncategorizedId) continue;
      final old = identities[c.id];
      if (mode != 'folder' && old != null) {
        if (old.kind != 'website_category' || old.deletedAt != null) {
          map[c.id] = uncategorizedId;
          plan.conflicts++;
          continue;
        }
        map[c.id] = old.id;
        if (replaceDefaults &&
            draft.fullSnapshot &&
            old.flag('isSystemPreset') &&
            !old.flag('userModified')) {
          final parent = c.input.parentId.isEmpty
              ? ''
              : map[c.input.parentId] ?? uncategorizedId;
          plan.categories.add((item: c, id: c.id, parent: parent, update: old));
          plan.categoryNames[c.id] = c.input.name;
        }
        continue;
      }
      final parent = mode == 'folder'
          ? map[uncategorizedId]!
          : c.input.parentId.isEmpty
          ? ''
          : map[c.input.parentId] ?? '';
      final label = mode == 'folder' && c.input.parentId.isNotEmpty
          ? '${draft.categories.firstWhere((p) => p.id == c.input.parentId).input.name} / ${c.input.name}'
          : c.input.name;
      final existing = liveCategories
          .where(
            (v) =>
                v.parentId == parent &&
                v.name.toLowerCase() == label.toLowerCase(),
          )
          .firstOrNull;
      final pending = plan.categories
          .where(
            (v) =>
                v.parent == parent &&
                v.item.input.name.toLowerCase() == label.toLowerCase(),
          )
          .firstOrNull;
      if (existing != null || pending != null) {
        map[c.id] = existing?.id ?? pending!.id;
        continue;
      }
      final id = mode == 'folder' ? newId() : c.id;
      final item = WebImportCategory(
        id,
        WebsiteCategoryInput(
          label,
          description: c.input.description,
          iconKey: c.input.iconKey,
          parentId: parent,
          color: c.input.color,
          sortOrder: c.input.sortOrder,
          isHidden: c.input.isHidden,
        ),
        originalPath: c.originalPath,
        isSystemPreset: mode == 'folder' ? false : c.isSystemPreset,
        userModified: c.userModified,
      );
      item.input.validate();
      map[c.id] = id;
      plan.categories.add((item: item, id: id, parent: parent, update: null));
      plan.categoryNames[id] = label;
    }
    final seen = <String>{},
        incomingUrls = draft.sites.map((s) => s.input.validate()).toSet();
    for (final s in draft.sites) {
      final url = s.input.validate();
      if (!seen.add(url)) {
        plan.duplicates++;
        continue;
      }
      final old = identities[s.id],
          duplicate = liveSites
              .where((v) => v.record.text('normalizedUrl') == url)
              .firstOrNull;
      if (old != null || duplicate != null) {
        final candidate = liveSites.where((v) => v.id == s.id).firstOrNull;
        if (replaceDefaults &&
            draft.fullSnapshot &&
            candidate != null &&
            _untouched(candidate) &&
            (duplicate == null || duplicate.id == candidate.id)) {
          plan.sites.add((
            item: s,
            category: map[s.input.categoryId] ?? uncategorizedId,
            update: candidate.record,
          ));
        } else if (duplicate != null) {
          plan.duplicates++;
        } else {
          plan.conflicts++;
        }
        continue;
      }
      plan.sites.add((
        item: s,
        category: map[s.input.categoryId] ?? uncategorizedId,
        update: null,
      ));
    }
    if (replaceDefaults && draft.fullSnapshot && mode != 'folder') {
      final ids = draft.sites.map((s) => s.id).toSet();
      plan.pruneSites.addAll(
        liveSites.where(
          (s) =>
              _untouched(s) &&
              !ids.contains(s.id) &&
              !incomingUrls.contains(s.record.text('normalizedUrl')),
        ),
      );
      final keptSites = liveSites.where(
        (s) =>
            !plan.pruneSites.any((p) => p.id == s.id) &&
            !plan.sites.any((p) => p.update?.id == s.id),
      );
      final retainedCategoryIds = {
        ...keptSites.map((s) => s.categoryId),
        ...plan.sites.map((s) => s.category),
        ...draft.categories.map((c) => map[c.id]),
        uncategorizedId,
      };
      // 先保留所有用户分类与其上级，再删除没有引用的未修改默认分类。
      for (final c in liveCategories.where(
        (c) => !c.isSystemPreset || c.record.flag('userModified'),
      )) {
        retainedCategoryIds.add(c.id);
        if (c.parentId.isNotEmpty) retainedCategoryIds.add(c.parentId);
      }
      for (final c in liveCategories) {
        if (retainedCategoryIds.contains(c.id) && c.parentId.isNotEmpty) {
          retainedCategoryIds.add(c.parentId);
        }
      }
      plan.pruneCategories.addAll(
        liveCategories.where(
          (c) =>
              c.isSystemPreset &&
              !c.record.flag('userModified') &&
              !retainedCategoryIds.contains(c.id),
        ),
      );
    }
    if (liveSites.length -
                plan.pruneSites.length +
                plan.sites.where((s) => s.update == null).length >
            10000 ||
        liveCategories.length -
                plan.pruneCategories.length +
                plan.categories.where((c) => c.update == null).length >
            16384) {
      throw const ToolFailure('导入后将超过网站或分类上限。');
    }
    return plan;
  }

  Future<ToolRecord> preview(
    WebImportDraft draft,
    String name, {
    String mode = 'merge',
    bool replaceDefaults = false,
  }) async {
    await repository.initialize();
    if (replaceDefaults && (!draft.fullSnapshot || mode == 'folder')) {
      throw const ToolFailure('只有完整JSON快照可替换未修改默认项。');
    }
    final payload = {
      'schemaVersion': 2,
      'scope': draft.fullSnapshot ? 'all' : 'selection',
      'categories': draft.categories.map(_categoryJson).toList(),
      'websites': draft.sites.map(_siteJson).toList(),
    };
    final encoded = utf8.encode(jsonEncode(payload));
    if (encoded.length > WebImportReader.byteLimit) {
      throw const ToolFailure('规范化数据超过20MiB，请分批导入。');
    }
    return store.transaction(() async {
      final plan = await _plan(draft, mode, replaceDefaults);
      return store.create(
        'web_import_preview',
        name,
        data: {
          'payloadVersion': 1,
          'payload': payload,
          'mode': mode,
          'replaceDefaults': replaceDefaults,
          'fingerprint': await _fingerprint(),
          'valid': draft.sites.length,
          'errors': draft.errors,
          'warnings': draft.warnings,
          'duplicates': plan.duplicates,
          'sourceDuplicates': draft.duplicates,
          'conflicts': plan.conflicts,
          'toWrite': plan.sites.length,
          'newCategories': plan.categories
              .where((c) => c.update == null)
              .length,
          'replaceDefaultsCount': plan.pruneSites.length,
          'status': 'preview',
          'syncAllowed': false,
        },
      );
    });
  }

  Future<ToolRecord> commit(
    ToolRecord preview,
    UtilityJobContext job, {
    required bool confirmed,
    bool skipInvalid = false,
  }) async {
    if (!confirmed ||
        preview.kind != 'web_import_preview' ||
        preview.text('status') != 'preview') {
      throw const ToolFailure('请先核对有效预览并明确确认。');
    }
    if (preview.strings('errors').isNotEmpty && !skipInvalid) {
      throw const ToolFailure('文件含无效条目，请修正，或明确选择跳过错误后导入。');
    }
    job.check();
    final draft = await WebImportReader.read(
      Uint8List.fromList(utf8.encode(jsonEncode(preview.data['payload']))),
      'json',
    );
    if (draft.errors.isNotEmpty) throw const ToolFailure('预览数据已损坏，请重新读取原文件。');
    final owned = await files(),
        iconService = WebIconService(store, files),
        prepared = <String, String>{},
        createdPaths = <String>[];
    var committed = false;
    try {
      final preflight = await store.transaction(() async {
        if (await _fingerprint() != preview.text('fingerprint')) {
          throw const ToolFailure('网站或分类已变化，请重新预览。');
        }
        return _plan(
          draft,
          preview.text('mode'),
          preview.flag('replaceDefaults'),
        );
      });
      final acceptedIds = preflight.sites.map((s) => s.item.id).toSet();
      // 只准备实际接受的图标；解码不占SQLite事务，失败清除本批新附件。
      for (final s in draft.sites.where(
        (s) => s.iconBytes != null && acceptedIds.contains(s.id),
      )) {
        job.check();
        final bytes = await iconService.prepare(s.iconBytes!);
        final path = await owned.write('web_icons', bytes, extension: 'png');
        createdPaths.add(path);
        prepared[s.id] = path;
      }
      job.check();
      final batch = await store.transaction(() async {
        final current = await store.get(preview.id);
        if (current?.revision != preview.revision ||
            current?.text('status') != 'preview' ||
            await _fingerprint() != preview.text('fingerprint')) {
          throw const ToolFailure('网站或分类已变化，请重新生成预览后确认。');
        }
        final plan = await _plan(
          draft,
          preview.text('mode'),
          preview.flag('replaceDefaults'),
        );
        for (final c in plan.categories) {
          job.check();
          final data = {
            ...c.update?.data ?? {},
            'parentId': c.parent,
            'iconKey': c.item.input.iconKey,
            'color': c.item.input.color,
            'sortOrder': c.item.input.sortOrder,
            'isHidden': c.item.input.isHidden,
            'isSystemPreset':
                c.update?.flag('isSystemPreset') ?? c.item.isSystemPreset,
            'originalPath': c.item.originalPath,
            'userModified': c.item.userModified,
            'syncAllowed': false,
          };
          if (c.update == null) {
            await store.createWithId(
              c.id,
              'website_category',
              c.item.input.name,
              body: c.item.input.description,
              data: data,
            );
          } else {
            await store.save(
              c.update!.copyWith(
                title: c.item.input.name,
                body: c.item.input.description,
                data: data,
              ),
            );
          }
        }
        var count = 0;
        for (final entry in plan.sites) {
          job.check();
          final s = entry.item, input = s.input;
          final data = websiteRecordData(
            WebsiteInput(
              input.title,
              input.url,
              categoryId: entry.category,
              description: input.description,
              tags: input.tags,
              isFavorite: input.isFavorite,
              isPinned: input.isPinned,
              alternateUrl: input.alternateUrl,
            ),
            input.validate(),
            categoryName: plan.categoryNames[entry.category] ?? '未分类',
            order: s.order,
            extra: {
              'source': 'import',
              'sourceType': s.sourceType,
              'isSeeded': s.isSeeded,
              'originIsSeeded': s.isSeeded,
              'visitCount': s.visitCount,
              'lastVisitedAt': s.lastVisitedAt?.toUtc().toIso8601String() ?? '',
              'originalPath': s.originalPath,
              'userModified': s.userModified,
            },
          );
          if (prepared.containsKey(s.id)) {
            final attachment = await store.create(
              'web_icon',
              '导入的网站图标',
              data: {
                'attachment': prepared[s.id],
                'websiteId': s.id,
                'syncAllowed': false,
              },
            );
            data['customIconPath'] = prepared[s.id];
            data['customIconId'] = attachment.id;
          }
          if (entry.update == null) {
            await store.createWithId(
              s.id,
              'favorite',
              input.title,
              body: input.description,
              data: data,
              createdAt: s.createdAt,
            );
          } else {
            await store.save(
              entry.update!.copyWith(
                title: input.title,
                body: input.description,
                data: data,
              ),
            );
            if (s.createdAt != null) {
              await (store.db.update(store.db.localRecords)
                    ..where((t) => t.id.equals(s.id)))
                  .write(LocalRecordsCompanion(createdAt: Value(s.createdAt!)));
            }
          }
          count++;
          await job.progress(
            count,
            plan.sites.length,
            currentFile: '网站 $count',
          );
        }
        if (plan.pruneSites.isNotEmpty) {
          await repository.removeWebsites(plan.pruneSites, confirmed: true);
        }
        for (final c in plan.pruneCategories) {
          job.check();
          await store.delete(c.record);
        }
        job.check();
        final result = await store.create(
          'web_import_batch',
          preview.title,
          data: {
            'previewId': preview.id,
            'jobId': job.id,
            'status': 'completed',
            'imported': count,
            'duplicates': plan.duplicates + preview.number('sourceDuplicates'),
            'conflicts': plan.conflicts,
            'invalid': preview.strings('errors').length,
            'categories': plan.categories.length,
            'syncAllowed': false,
          },
        );
        // 删除预览中的私有副本；批次仅留计数和ID，不保存网址日志。
        await store.save(
          current!.copyWith(
            data: {
              ...current.data,
              'payload': null,
              'status': 'completed',
              'batchId': result.id,
            },
          ),
        );
        await job.output(result.id);
        job.check();
        return result;
      });
      committed = true;
      return batch;
    } catch (_) {
      if (!committed) {
        for (final path in createdPaths) {
          await owned.remove(path);
        }
      }
      rethrow;
    }
  }

  Future<Uint8List> export(
    String format, {
    List<String>? ids,
    bool includeIcons = true,
  }) async {
    await repository.initialize();
    var sites = await repository.sites();
    final categories = await repository.categories();
    if (ids != null) {
      final selection = ids.toSet();
      if (selection.length != ids.length ||
          !selection.every((id) => sites.any((s) => s.id == id))) {
        throw const ToolFailure('导出选择已变化，请重新选择。');
      }
      sites = sites.where((s) => selection.contains(s.id)).toList();
    }
    final records = <Map<String, dynamic>>[], owned = await files();
    for (final s in sites) {
      Uint8List? icon;
      if (includeIcons && format == 'json' && s.customIconPath.isNotEmpty) {
        final file = owned.resolve(s.customIconPath);
        if (!await file.exists()) {
          throw const ToolFailure('自定义图标附件缺失，请恢复备份或清除图标后导出。');
        }
        if (await file.length() > 256 * 1024) {
          throw const ToolFailure('图标附件大小异常。');
        }
        icon = await file.readAsBytes();
      }
      final c = categories.where((c) => c.id == s.categoryId).firstOrNull,
          parent = categories.where((p) => p.id == c?.parentId).firstOrNull;
      records.add({
        ..._siteJson(
          WebImportSite(
            s.id,
            WebsiteInput(
              s.title,
              s.url,
              description: s.description,
              categoryId: s.categoryId,
              tags: s.tags,
              isFavorite: s.isFavorite,
              isPinned: s.isPinned,
              alternateUrl: s.record.text('alternateUrl'),
            ),
            order: s.sortOrder,
            createdAt: s.record.createdAt,
            lastVisitedAt: s.lastVisitedAt,
            visitCount: s.visitCount,
            isSeeded: s.isSeeded,
            userModified: s.record.flag('userModified'),
            sourceType: s.sourceType,
            iconBytes: icon,
          ),
        ),
        'categoryPath': [
          if (parent != null) parent.name,
          if (c != null) c.name,
        ],
      });
    }
    final exportedCategories = categories
        .map(
          (c) => _categoryJson(
            WebImportCategory(
              c.id,
              WebsiteCategoryInput(
                c.name,
                description: c.description,
                parentId: c.parentId,
                iconKey: c.iconKey,
                color: c.color,
                sortOrder: c.sortOrder,
                isHidden: c.isHidden,
              ),
              isSystemPreset: c.isSystemPreset,
              userModified: c.record.flag('userModified'),
            ),
          ),
        )
        .toList();
    return Isolate.run(
      _EncodeWebFile(format, {
        'schemaVersion': 2,
        'scope': ids == null ? 'all' : 'selection',
        'categories': exportedCategories,
        'websites': records,
      }).call,
    );
  }
}

class _EncodeWebFile {
  _EncodeWebFile(this.format, this.payload);
  final String format;
  final Map<String, dynamic> payload;
  static String escape(Object? value) =>
      const HtmlEscape(HtmlEscapeMode.attribute).convert('$value');
  static String cell(Object? value) {
    final s = '$value';
    return RegExp(r'^[\s]*[=+\-@\t\r]').hasMatch(s) ? "'$s" : s;
  }

  Uint8List call() {
    final sites = (payload['websites'] as List).cast<Map<String, dynamic>>(),
        categories = (payload['categories'] as List)
            .cast<Map<String, dynamic>>();
    late String result;
    if (format == 'json') {
      result = const JsonEncoder.withIndent('  ').convert(payload);
    } else if (format == 'csv') {
      result =
          '\ufeff${csv.encode([
            ['title', 'url', 'description', 'categoryPath', 'tags', 'isFavorite', 'isPinned'],
            ...sites.map((s) => [cell(s['title']), s['url'], cell(s['description']), jsonEncode(s['categoryPath']), jsonEncode(s['tags']), s['isFavorite'], s['isPinned']]),
          ])}';
    } else if (format == 'html') {
      final out = StringBuffer(
        '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">\n<TITLE>Web Library</TITLE><H1>Web Library</H1>\n<DL><p>\n',
      );
      void folder(Map<String, dynamic> c) {
        out.writeln(
          '<DT><H3 DATA-KADO-ID="${c['id']}">${escape(c['name'])}</H3>\n<DL><p>',
        );
        for (final s in sites.where((s) => s['categoryId'] == c['id'])) {
          out.writeln(
            '<DT><A HREF="${escape(s['url'])}" DATA-KADO-ID="${s['id']}" DATA-KADO-TAGS="${escape(jsonEncode(s['tags']))}" DATA-KADO-DESCRIPTION="${escape(s['description'])}" DATA-KADO-FAVORITE="${s['isFavorite']}" DATA-KADO-PINNED="${s['isPinned']}">${escape(s['title'])}</A>',
          );
        }
        for (final child in categories.where((v) => v['parentId'] == c['id'])) {
          folder(child);
        }
        out.writeln('</DL><p>');
      }

      for (final c in categories.where((c) => c['parentId'] == '')) {
        folder(c);
      }
      out.writeln('</DL><p>');
      result = out.toString();
    } else {
      throw const ToolFailure('只支持JSON、HTML、CSV导出。');
    }
    final bytes = Uint8List.fromList(utf8.encode(result));
    if (bytes.length > WebImportReader.byteLimit) {
      throw const ToolFailure('导出超过20MiB，请分批选择。');
    }
    return bytes;
  }
}
