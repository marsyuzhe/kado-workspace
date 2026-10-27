import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import 'web_catalog.dart';
import 'web_icons.dart';
import 'web_models.dart';
import 'web_repository.dart';
import 'web_search_service.dart';
import 'web_transfer.dart';

final webRepositoryProvider = Provider(
  (ref) => WebLibraryRepository(ref.watch(recordStoreProvider)),
);
final webCategoriesProvider = StreamProvider.autoDispose<List<WebsiteCategory>>(
  (ref) => ref.watch(webRepositoryProvider).watchCategories(),
);
final webTrashProvider = StreamProvider.autoDispose<List<WebsiteBookmark>>(
  (ref) => ref.watch(webRepositoryProvider).watchTrash(),
);
final webCatalogProvider = FutureProvider.autoDispose(
  (ref) => WebCatalog.bundled(),
);
final webTransferProvider = Provider(
  (ref) => WebTransferService(
    ref.watch(webRepositoryProvider),
    () => ref.read(ownedFilesProvider.future),
  ),
);
final webIconsProvider = Provider(
  (ref) => WebIconService(
    ref.watch(recordStoreProvider),
    () => ref.read(ownedFilesProvider.future),
  ),
);

class WebPreviewSummary {
  const WebPreviewSummary(this.id, this.title, this.count, this.errors);
  final String id, title;
  final int count, errors;
}

final webPreviewSummariesProvider = StreamProvider.autoDispose(
  (ref) => ref
      .watch(recordStoreProvider)
      .db
      .customSelect(
        "SELECT id,title,json_extract(data,'\$.toWrite') AS n,json_array_length(json_extract(data,'\$.errors')) AS errors FROM local_records WHERE kind='web_import_preview' AND deleted_at IS NULL AND json_extract(data,'\$.status')='preview' ORDER BY updated_at DESC LIMIT 20",
        readsFrom: {ref.read(recordStoreProvider).db.localRecords},
      )
      .watch()
      .map(
        (rows) => rows
            .map(
              (r) => WebPreviewSummary(
                r.read<String>('id'),
                r.read<String>('title'),
                r.read<int>('n'),
                r.read<int>('errors'),
              ),
            )
            .toList(),
      ),
);
typedef WebQuery = ({
  String text,
  String category,
  String view,
  String sort,
  int offset,
});
final webResultsProvider = StreamProvider.autoDispose
    .family<WebPageResult, WebQuery>((ref, q) async* {
      final repo = ref.watch(webRepositoryProvider);
      await repo.initialize();
      // 与网页无关的记录变动不触发重新搜索；页面销毁后取消监听。
      yield* repo.store.db
          .customSelect(
            "SELECT COUNT(*) AS n,COALESCE(SUM(revision),0) AS rev FROM local_records WHERE kind='website_category' OR (kind='favorite' AND json_extract(data,'\$.action.type')='url')",
            readsFrom: {repo.store.db.localRecords},
          )
          .watch()
          .map(
            (rows) =>
                (rows.single.read<int>('n'), rows.single.read<int>('rev')),
          )
          .distinct()
          .asyncMap(
            (_) => WebLibrarySearchService(repo.store).search(
              q.text,
              categoryId: q.category,
              view: q.view,
              sort: q.sort,
              offset: q.offset,
            ),
          );
    });
