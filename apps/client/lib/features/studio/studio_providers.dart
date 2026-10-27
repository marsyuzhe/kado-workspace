import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import 'agent_runtime.dart';
import 'studio_repository.dart';

final studioRepositoryProvider = Provider<StudioRepository>(
  (ref) => StudioRepository(ref.watch(recordStoreProvider)),
);
final toolRegistryProvider = Provider((ref) => ToolRegistry());
final agentRuntimeProvider = Provider<AgentRuntime>((ref) {
  final repository = ref.watch(studioRepositoryProvider),
      memory = ref.watch(memoryRepositoryProvider);
  final runtime = AgentRuntime(
    repository,
    memory,
    LocalToolExecutor(repository, memory, ref.watch(toolRegistryProvider)),
    LLMApiExecutor(
      repository,
      ref.watch(aiRepositoryProvider),
      ref.watch(aiApiProvider),
    ),
  );
  ref.onDispose(() => unawaited(runtime.dispose()));
  return runtime;
});
final studioReadyProvider = FutureProvider(
  (ref) => ref.watch(agentRuntimeProvider).initialize(),
);
