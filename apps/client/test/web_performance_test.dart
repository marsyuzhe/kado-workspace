import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/features/utilities/bookmark_query.dart';
import 'package:links_toolbox/features/web_library/web_models.dart';
import 'package:links_toolbox/features/web_library/web_repository.dart';
import 'package:links_toolbox/features/web_library/web_search_service.dart';

import 'web_library_test.dart' show fixtureCatalog;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measure same-mode SQLite search on 1000 owned records without invented thresholds', () async {
    final temp = await Directory.systemTemp.createTemp('kado-web-perf-'),
        db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    final store = RecordStore(db),
        repo = WebLibraryRepository(
          store,
          catalog: () async => fixtureCatalog(),
        );
    try {
      await repo.initialize();
      await store.transaction(() async {
        for (var i = 0; i < 1000; i++) {
          final input = WebsiteInput(
            'Measure ${i.toString().padLeft(4, '0')}',
            'https://perf.example.org/$i',
            categoryId: uncategorizedId,
            tags: ['fixture'],
          );
          await store.create(
            'favorite',
            input.title,
            data: websiteRecordData(
              input,
              input.url,
              categoryName: '未分类',
              order: i,
            ),
          );
        }
      });
      final search = WebLibrarySearchService(store);
      await search.search('Measure 099');
      await searchLocalBookmarks(store, 'Measure 099');
      final old = <int>[], current = <int>[];
      for (var i = 0; i < 15; i++) {
        // Alternate order to avoid consistently warming one method for the other.
        Future<void> baseline() async {
          final w = Stopwatch()..start(),
              rows = await searchLocalBookmarks(store, 'Measure 099');
          w.stop();
          expect(rows.length, 10);
          old.add(w.elapsedMicroseconds);
        }

        Future<void> candidate() async {
          final w = Stopwatch()..start(),
              page = await search.search('Measure 099');
          w.stop();
          expect(page.total, 10);
          current.add(w.elapsedMicroseconds);
        }

        if (i.isEven) {
          await baseline();
          await candidate();
        } else {
          await candidate();
          await baseline();
        }
      }
      int median(List<int> values) {
        final sorted = [...values]..sort();
        return sorted[sorted.length ~/ 2];
      }

      final plan = await store.db
          .customSelect(
            "EXPLAIN QUERY PLAN SELECT id FROM local_records WHERE kind='favorite' AND deleted_at IS NULL AND json_extract(data,'\$.action.type')='url' AND json_extract(data,'\$.normalizedUrl')='https://perf.example.org/999'",
          )
          .get();
      expect(plan.any((r) => '${r.data}'.contains('web_sites_url')), isTrue);
      final out = File('../../artifacts/v23-performance/web_queries.json');
      await out.parent.create(recursive: true);
      await out.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'mode': 'Flutter test/JIT, local SQLite, one machine, warmed; NOT Release UI latency',
          'rows': 1003,
          'samples': 15,
          'baseline': 'unchanged 2.0 searchLocalBookmarks helper, title/body/URL/tags/category, limit101',
          'candidate': '2.3 relational SQL search, includes parent/hidden/personal, count+pagination60',
          'sameTitleQueryMatches': 10,
          'baselineMedianMicroseconds': median(old),
          'candidateMedianMicroseconds': median(current),
          'baselineSamples': old,
          'candidateSamples': current,
          'urlLookupExplain': plan.map((r) => r.data).toList(),
          'firstFrame': 'UNMEASURED',
          'studioReleaseLoad': 'UNMEASURED',
        }),
      );
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
}
