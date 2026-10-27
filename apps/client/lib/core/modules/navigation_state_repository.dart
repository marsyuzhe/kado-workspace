import 'dart:convert';

import '../data/record_store.dart';

class NavigationState {
  const NavigationState({
    this.compact = false,
    this.width = 232,
    this.workspaceOpen = true,
    this.closedGroups = const {},
    this.visibleLegacy = const {},
    this.order = const [],
  });
  final bool compact, workspaceOpen;
  final double width;
  final Set<String> closedGroups, visibleLegacy;
  final List<String> order;
  NavigationState copyWith({
    bool? compact,
    double? width,
    bool? workspaceOpen,
    Set<String>? closedGroups,
    Set<String>? visibleLegacy,
    List<String>? order,
  }) => NavigationState(
    compact: compact ?? this.compact,
    width: (width ?? this.width).clamp(196, 280),
    workspaceOpen: workspaceOpen ?? this.workspaceOpen,
    closedGroups: closedGroups ?? this.closedGroups,
    visibleLegacy: visibleLegacy ?? this.visibleLegacy,
    order: order ?? this.order,
  );
  Map<String, Object> toJson() => {
    'version': 1,
    'compact': compact,
    'width': width,
    'workspaceOpen': workspaceOpen,
    'closedGroups': closedGroups.toList(),
    'visibleLegacy': visibleLegacy.toList(),
    'order': order,
  };
  factory NavigationState.fromJson(Map<String, dynamic> json) {
    Set<String> strings(String key) =>
        (json[key] is List
                ? (json[key] as List).whereType<String>().take(100)
                : <String>[])
            .toSet();
    final rawWidth = json['width'];
    return NavigationState(
      compact: json['compact'] == true,
      width: rawWidth is num && rawWidth.isFinite
          ? rawWidth.toDouble().clamp(196, 280)
          : 232,
      workspaceOpen: json['workspaceOpen'] != false,
      closedGroups: strings('closedGroups'),
      visibleLegacy: strings('visibleLegacy'),
      order: strings('order').toList(),
    );
  }
}

/// One versioned setting avoids a schema change. Hidden modules retain all data.
class NavigationStateRepository {
  NavigationStateRepository(this.store);
  final RecordStore store;
  Future<NavigationState> load() async {
    final raw = await store.setting('workspace.navigation.v1');
    if (raw == null) return const NavigationState();
    // Invalid persisted settings are reported, rather than silently overwritten.
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) throw const FormatException('导航设置无效');
    return NavigationState.fromJson(value);
  }

  Future<void> save(NavigationState state) =>
      store.setSetting('workspace.navigation.v1', jsonEncode(state.toJson()));
}
