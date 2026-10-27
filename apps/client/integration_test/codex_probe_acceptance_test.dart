import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:links_toolbox/features/studio/codex_diagnostics.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native metadata-only Codex probe validates actual installed schema',
    (tester) async {
      final executable = Platform.environment['LINKS_CODEX_PROBE_EXE'];
      expect(
        executable,
        isNotNull,
        reason: 'This acceptance run requires an explicitly selected local CLI; it never invokes a model.',
      );
      final result = await CodexDiagnostics().inspect(executable!);
      expect(result.version, startsWith('codex-cli '));
      expect(result.taskExecutionEnabled, isFalse);
      final output = Directory(
        p.join(Platform.environment['LINKS_ARTIFACT_ROOT']!, 'codex'),
      );
      await output.create(recursive: true);
      await File(p.join(output.path, 'metadata-probe.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': result.version,
          'restrictedReadSupported': result.restrictedReadSupported,
          'schemaChecksum': result.schemaChecksum,
          'taskExecutionEnabled': result.taskExecutionEnabled,
          'explanation': result.explanation,
          'operations': ['--version', 'app-server generate-json-schema'],
          'realModelSession': 'UNVERIFIED',
          'authFilesReadByApplication': false,
        }),
      );
    },
  );
}
