import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/app/data_providers.dart';
import 'package:links_toolbox/app/providers.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/database/settings_repository.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/features/utilities/utility_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('interrupted finance batch is labelled without replay and completed batch stays complete', () async {
    final temp = await Directory.systemTemp.createTemp('lt-finance-recovery-'),
        db = AppDatabase.file(File('${temp.path}/test.sqlite'));
    await db.initialize();
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
      ],
    );
    try {
      final store = container.read(recordStoreProvider),
          repo = JobQueueRepository(store),
          job = await repo.create(
            'finance',
            'import',
            'Interrupted QA',
            {},
            submissionId: 'recover',
          );
      await repo.start(job.id);
      final pending = await store.create(
            'finance_batch',
            'Pending batch',
            data: {'jobId': job.id, 'status': 'processing'},
          ),
          complete = await store.create(
            'finance_batch',
            'Complete batch',
            data: {'jobId': job.id, 'status': 'complete'},
          );
      await container.read(utilityJobsReadyProvider.future);
      expect((await store.get(pending.id))!.text('status'), 'interrupted');
      expect((await store.get(complete.id))!.text('status'), 'complete');
      expect(await store.list('finance_transaction'), isEmpty);
      expect((await store.get(job.id))!.text('status'), 'interrupted');
    } finally {
      await container.read(utilityJobsProvider).dispose();
      container.dispose();
      await db.close();
      await temp.delete(recursive: true);
    }
  });
}
