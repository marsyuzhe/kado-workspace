import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/jobs/utility_jobs.dart';
import '../../core/data/tool_record.dart';
import '../../core/storage/utility_files.dart';
import 'media_converter.dart';
import 'document_converter.dart';
import 'transcribe_service.dart';
import 'media_library.dart';
import 'software_library.dart';
import 'environment_snapshot.dart';
import 'home_dashboard.dart';
import 'game_saves.dart';
import 'lan_transfer.dart';
import 'finance_service.dart';
import 'collection_service.dart';
import 'image_service.dart';

final utilityFilesProvider = Provider(
  (ref) => UtilityFileService(
    ref.watch(recordStoreProvider),
    () => ref.read(ownedFilesProvider.future),
    availableBytes: ref.watch(nativePlatformProvider).availableDiskBytes,
  ),
);
final utilityJobsProvider = Provider((ref) {
  final engine = UtilityJobEngine(
    JobQueueRepository(ref.watch(recordStoreProvider)),
  );
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});
final utilityJobsReadyProvider = FutureProvider((ref) async {
  await ref.watch(utilityJobsProvider).initialize();
  final store = ref.read(recordStoreProvider);
  for (final row in await store.list('transcript', limit: 10000)) {
    if (row.text('status') != 'processing') continue;
    final job = await store.get(row.text('jobId'));
    if (job == null || job.text('status') == 'interrupted') {
      await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'status': 'interrupted',
            'error': '上次识别未完成；已完成分段保留，请检查后重新创建任务。',
          },
        ),
      );
    }
  }
  for (final row in await store.list('finance_batch', limit: 10000)) {
    if (row.text('status') != 'processing') continue;
    final job = await store.get(row.text('jobId'));
    if (job == null || job.text('status') == 'interrupted') {
      await store.save(
        row.copyWith(
          data: {
            ...row.data,
            'status': 'interrupted',
            'error': '上次导入未提交，SQLite事务已回滚；请检查账本并重新预览，不自动重放。',
          },
        ),
      );
    }
  }
  for (final kind in ['game_backup', 'game_restore']) {
    for (final row in await store.list(kind, limit: 10000)) {
      if (!{'processing', 'committing'}.contains(row.text('status'))) continue;
      final job = await store.get(row.text('jobId'));
      if (job == null || job.text('status') == 'interrupted') {
        await store.save(
          row.copyWith(
            data: {
              ...row.data,
              'status': 'interrupted',
              'error': '上次任务中断。未自动重放；有完整哈希的正式ZIP可重新校验，临时文件保留供检查。',
            },
          ),
        );
      }
    }
  }
});
final mediaRuntimeProvider = Provider(
  (ref) => MediaRuntimeService(ref.watch(recordStoreProvider)),
);
final mediaConverterProvider = Provider(
  (ref) => MediaConverterService(
    ref.watch(recordStoreProvider),
    ref.watch(utilityFilesProvider),
    ref.watch(mediaRuntimeProvider),
    () async => Directory((await ref.read(appDirectoryProvider.future)).path),
  ),
);
final documentConverterProvider = Provider(
  (ref) => DocumentConverterService(
    ref.watch(recordStoreProvider),
    () => ref.read(ownedFilesProvider.future),
    () async =>
        (await rootBundle.load('assets/fonts/NotoSansSC.ttf')).buffer
            .asUint8List(),
  ),
);
final whisperRuntimeProvider = Provider(
  (ref) => WhisperRuntimeService(
    ref.watch(recordStoreProvider),
    ref.watch(mediaRuntimeProvider),
  ),
);
final speechModelsProvider = Provider(
  (ref) => SpeechModelManager(
    ref.watch(recordStoreProvider),
    ref.watch(utilityFilesProvider),
    () => ref.read(appDirectoryProvider.future),
  ),
);
final transcriptRepositoryProvider = Provider(
  (ref) => TranscriptRepository(ref.watch(recordStoreProvider)),
);
final transcribeServiceProvider = Provider(
  (ref) => TranscribeService(
    ref.watch(recordStoreProvider),
    ref.watch(mediaConverterProvider),
    ref.watch(whisperRuntimeProvider),
    ref.watch(speechModelsProvider),
    () => ref.read(appDirectoryProvider.future),
  ),
);
final mediaLibraryProvider = Provider(
  (ref) => MediaLibraryService(
    ref.watch(recordStoreProvider),
    ref.watch(mediaConverterProvider),
    ref.watch(utilityFilesProvider),
    () => ref.read(appDirectoryProvider.future),
  ),
);
final softwareLibraryProvider = Provider(
  (ref) => SoftwareLibraryService(
    ref.watch(recordStoreProvider),
    ref.watch(nativePlatformProvider),
  ),
);
final environmentSnapshotProvider = Provider(
  (ref) => EnvironmentSnapshotService(
    ref.watch(recordStoreProvider),
    ref.watch(nativePlatformProvider),
    ref.watch(utilityFilesProvider),
    () => ref.read(appDirectoryProvider.future),
  ),
);
final homeDashboardProvider = Provider(
  (ref) => HomeDashboardService(ref.watch(recordStoreProvider)),
);

final gameSavesProvider = Provider(
  (ref) => GameSaveService(
    ref.watch(recordStoreProvider),
    ref.watch(utilityFilesProvider),
    ref.watch(nativePlatformProvider),
  ),
);

final lanTransferProvider = Provider(
  (ref) => LanTransferService(
    ref.watch(recordStoreProvider),
    ref.watch(utilityFilesProvider),
    ref.watch(nativePlatformProvider),
  ),
);

final financeProvider = Provider(
  (ref) => FinanceService(
    ref.watch(recordStoreProvider),
    ref.watch(utilityFilesProvider),
  ),
);
final financeRowsProvider = StreamProvider.autoDispose(
  (ref) => ref.watch(financeProvider).watch(),
);
final financePreviewSummariesProvider = StreamProvider.autoDispose(
  (ref) => ref.watch(financeProvider).watchPreviewSummaries(),
);

final financePreviewProvider = StreamProvider.autoDispose
    .family<ToolRecord?, String>(
      (ref, id) => ref.watch(recordStoreProvider).watchOne(id),
    );
final collectionProvider = Provider(
  (ref) => CollectionService(
    ref.watch(recordStoreProvider),
    () => ref.read(ownedFilesProvider.future),
    ImageToolService(
      ref.watch(recordStoreProvider),
      () => ref.read(ownedFilesProvider.future),
    ),
  ),
);
final collectionRowsProvider = StreamProvider.autoDispose(
  (ref) => ref.watch(collectionProvider).watch(),
);
final collectionImagesProvider = StreamProvider.autoDispose
    .family<List<ToolRecord>, String>(
      (ref, id) => ref.watch(collectionProvider).watchImages(id),
    );
final collectionCardProvider = StreamProvider.autoDispose
    .family<ToolRecord?, String>(
      (ref, id) => ref.watch(recordStoreProvider).watchOne(id),
    );
