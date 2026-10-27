import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/modules/navigation_state_repository.dart';
import '../core/modules/workspace_navigation.dart';
import 'data_providers.dart';

final navigationStateRepositoryProvider = Provider(
  (ref) => NavigationStateRepository(ref.watch(recordStoreProvider)),
);
final sidebarControllerProvider =
    AsyncNotifierProvider<SidebarCollapseController, NavigationState>(
      SidebarCollapseController.new,
    );

/// Serial read-modify-write protects simultaneous resize/group changes.
/// Persistence failures reach the caller; the last committed state stays intact.
class SidebarCollapseController extends AsyncNotifier<NavigationState> {
  Future<void> _tail = Future.value();
  @override
  Future<NavigationState> build() =>
      ref.watch(navigationStateRepositoryProvider).load();
  Future<void> change(NavigationState Function(NavigationState) update) {
    final operation = _tail.then((_) async {
      final previous = state.asData?.value ?? await future;
      final next = update(previous);
      await ref.read(navigationStateRepositoryProvider).save(next);
      if (ref.mounted) state = AsyncData(next);
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> reveal(Uri uri) async {
    final matches = workspaceSections.where(
      (s) => s.items.any((i) => i.matches(uri)),
    );
    if (matches.isEmpty) return;
    final group = matches.first.id;
    final current = state.asData?.value ?? await future;
    if (current.workspaceOpen && !current.closedGroups.contains(group)) return;
    await change(
      (s) => s.copyWith(
        workspaceOpen: true,
        closedGroups: {...s.closedGroups}..remove(group),
      ),
    );
  }
}
