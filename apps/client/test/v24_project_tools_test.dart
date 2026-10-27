import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/jobs/utility_jobs.dart';
import 'package:links_toolbox/core/storage/utility_files.dart';
import 'package:links_toolbox/core/storage/owned_file_store.dart';
import 'package:links_toolbox/features/dev_tools/api_studio_service.dart';
import 'package:links_toolbox/features/dev_tools/github_projects.dart';
import 'package:links_toolbox/features/dev_tools/project_inspection_service.dart';
import 'package:links_toolbox/features/dev_tools/workflow_service.dart';
import 'package:links_toolbox/features/dev_tools/controlled_worker.dart';
import 'package:links_toolbox/features/server/server_service.dart';

import 'ai_test.dart' show TestCredentials;

void main() {
  test('four actual dependency parsers keep scopes and never execute manifest scripts', () async {
    for (final (name, text, expected) in [
      (
        'pubspec.yaml',
        'name: local\ndependencies:\n  dio: ^5.0.0\ndev_dependencies:\n  test: any\n',
        2,
      ),
      (
        'package.json',
        '{"dependencies":{"x":"1.0"},"scripts":{"preinstall":"do-not-run"}}',
        1,
      ),
      (
        'requirements.txt',
        'requests>=2.0\n-r hidden-secrets.txt\nnumpy==1.0; python_version>"3.8"\n',
        2,
      ),
      (
        'Cargo.toml',
        '[dependencies]\nserde = {version="1", features=["derive"]}\n[target.\'cfg(windows)\'.dependencies]\nwindows="0.1"\n',
        2,
      ),
    ]) {
      final result =
          await ControlledWorker(inspectDependencies, {
                'name': name,
                'text': text,
              }).result
              as Map;
      expect((result['dependencies'] as List).length, expected);
    }
    await expectLater(
      ControlledWorker(inspectDependencies, {
        'name': 'Cargo.toml',
        'text': '[invalid',
      }).result,
      throwsException,
    );
    await expectLater(
      ControlledWorker(inspectDependencies, {
        'name': 'unknown',
        'text': 'noop',
      }).result,
      throwsException,
    );
  });
  test('snapshot diff software tools and environment names excludes all secret values', () async {
    final before = jsonEncode({
          'schemaVersion': 1,
          'tools': [
            {'id': 'dart', 'version': '3.0'},
          ],
          'environmentVariableNames': ['OLD', 'PATH'],
          'environmentValues': {'SECRET': 'NEVER_EXPORT'},
        }),
        after = jsonEncode({
          'schemaVersion': 1,
          'tools': [
            {'id': 'dart', 'version': '3.1'},
            {'id': 'git', 'version': '2'},
          ],
          'environmentVariableNames': ['NEW', 'PATH'],
          'environmentValues': {'SECRET': 'NEVER_EXPORT'},
        });
    final result =
        await ControlledWorker(diffEnvironment, {
              'before': before,
              'after': after,
              'beforeCsv': 'name,id,version\nA,a,1\nB,b,1',
              'afterCsv': 'name,id,version\nA,a,2\nC,c,1',
            }).result
            as Map;
    expect((result['tools'] as List).length, 2);
    expect((result['software'] as List).length, 3);
    expect(result['environmentNamesAdded'], ['NEW']);
    expect(result['environmentNamesRemoved'], ['OLD']);
    expect(jsonEncode(result), isNot(contains('NEVER_EXPORT')));
  });
  test('Docker command boundary accepts only fixed read operations and hexadecimal IDs', () {
    const id = 'abcdef123456';
    for (final type in ['logs', 'stats']) {
      expect(isReadOnlyServerCommand(dockerReadCommand(type, id)), true);
    }
    expect(
      isReadOnlyServerCommand("docker image ls --format '{{json .}}'"),
      true,
    );
    for (final command in [
      'docker restart $id',
      'docker rm $id',
      'docker logs --tail 200 --timestamps $id; touch /tmp/no',
      'docker stats --no-stream $id',
    ]) {
      expect(isReadOnlyServerCommand(command), false);
    }
    expect(() => dockerReadCommand('logs', 'id;whoami'), throwsException);
  });
  test('workflow real JSON conversion hash exclusive export preserved input and cancellation', () async {
    final temp = await Directory.systemTemp.createTemp('v24-workflow-test-'),
        db = AppDatabase.file(File('${temp.path}/db.sqlite'));
    await db.initialize();
    final store = RecordStore(db),
        files = UtilityFileService(store, () async => OwnedFileStore(temp)),
        service = LocalWorkflowService(store, files);
    final input = File('${temp.path}/source.json');
    await input.writeAsString('{"中文":1}');
    final out = await Directory('${temp.path}/output').create(),
        repo = JobQueueRepository(store);
    final row = await repo.create(
      'workflow',
      'run',
      'test',
      {},
      submissionId: 'actual-workflow',
    );
    await repo.start(row.id);
    final job = UtilityJobContext(row.id, repo);
    final result = await service.run(input.path, out.path, [
      'json-format',
    ], job);
    expect(await input.readAsString(), '{"中文":1}');
    final output = File(result.text('path'));
    expect(jsonDecode(await output.readAsString()), {'中文': 1});
    expect(result.text('sha256'), hasLength(64));
    expect(result.text('sha512'), hasLength(128));
    expect(
      (await repo.require(row.id)).strings('outputReferences'),
      contains(result.id),
    );
    job.cancellation.cancel();
    await expectLater(
      service.run(input.path, out.path, ['copy'], job),
      throwsException,
    );
    expect((await out.list().toList()).length, 1);
    await db.close();
    await temp.delete(recursive: true);
  });
  test(
    'public GitHub manual acceptance without token',
    () async {
      final temp = await Directory.systemTemp.createTemp('v24-github-'),
          db = AppDatabase.file(File('${temp.path}/db.sqlite'));
      await db.initialize();
      final store = RecordStore(db),
          service = GitHubProjectService(
            store,
            ApiStudioService(store, TestCredentials()),
          );
      try {
        final result = await service.fetch('flutter/flutter');
        expect(result['repository'], 'flutter/flutter');
        expect(result['stars'], isA<int>());
        final saved = await service.save('flutter/flutter', snapshot: result);
        expect((await store.get(saved.id))!.data['snapshot'], isA<Map>());
        final evidence = File('../../artifacts/v24-github-public.json');
        await evidence.writeAsString(jsonEncode(result));
      } finally {
        await db.close();
        await temp.delete(recursive: true);
      }
    },
    skip: Platform.environment['KADO_GITHUB_NETWORK'] != '1'
        ? 'Explicit external-network acceptance only'
        : false,
  );
}
