import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import 'timeline_service.dart';
import 'timeline_reminder_service.dart';

final timelineServiceProvider = Provider(
  (ref) => PersonalTimeline(ref.watch(recordStoreProvider)),
);
final timelineRowsProvider = StreamProvider.autoDispose(
  (ref) => ref.watch(timelineServiceProvider).watch(),
);
final timelineReminderServiceProvider = Provider(
  (ref) => TimelineReminderService(ref.watch(recordStoreProvider)),
);
final timelinePendingRemindersProvider = StreamProvider.autoDispose(
  (ref) => ref.watch(timelineReminderServiceProvider).watchPending(),
);

class TimelineReminderStatus {
  const TimelineReminderStatus({
    this.enabled = false,
    this.error = '',
    this.lastChecked,
  });
  final bool enabled;
  final String error;
  final DateTime? lastChecked;
}

class TimelineReminderController extends Notifier<TimelineReminderStatus> {
  Timer? _timer;
  Future<void>? _initialization, _polling;
  bool _stopped = false;
  @override
  TimelineReminderStatus build() {
    ref.onDispose(() {
      _stopped = true;
      _timer?.cancel();
    });
    return const TimelineReminderStatus();
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      final enabled =
          await ref.read(recordStoreProvider).setting(reminderSetting) ==
          'true';
      if (!ref.mounted || _stopped) return;
      state = TimelineReminderStatus(enabled: enabled);
      if (enabled) _start();
    } catch (_) {
      if (ref.mounted) {
        state = const TimelineReminderStatus(error: '应用内提醒读取失败，原有待办保留。');
      }
    }
  }

  void _start() {
    _stopped = false;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(poll()),
    );
    unawaited(poll());
  }

  Future<void> enable(bool enabled) async {
    await initialize();
    await ref.read(recordStoreProvider).setSetting(reminderSetting, '$enabled');
    if (!ref.mounted) return;
    _timer?.cancel();
    state = TimelineReminderStatus(enabled: enabled);
    if (enabled) _start();
  }

  Future<void> poll() {
    if (_stopped || !ref.mounted || !state.enabled) return Future.value();
    return _polling ??= _doPoll().whenComplete(() => _polling = null);
  }

  Future<void> _doPoll() async {
    try {
      await ref
          .read(timelineReminderServiceProvider)
          .poll(DateTime.now().toUtc());
      if (ref.mounted && !_stopped) {
        state = TimelineReminderStatus(
          enabled: state.enabled,
          lastChecked: DateTime.now().toUtc(),
        );
      }
    } catch (_) {
      if (ref.mounted && !_stopped) {
        state = TimelineReminderStatus(
          enabled: state.enabled,
          error: '提醒检查失败，未显示伪成功；请检查本地存储。',
        );
      }
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    await _polling;
  }
}

final timelineReminderControllerProvider =
    NotifierProvider<TimelineReminderController, TimelineReminderStatus>(
      TimelineReminderController.new,
    );
