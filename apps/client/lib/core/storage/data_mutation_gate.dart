import 'dart:async';

/// Reentrant within one async operation. Database transactions and owned files
/// share this gate so a backup snapshots referenced attachment contents together.
class DataMutationGate {
  static final shared = DataMutationGate();
  final Object _zoneKey = Object();
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() action) async {
    if (Zone.current[_zoneKey] == this) return action();
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await runZoned(action, zoneValues: {_zoneKey: this});
    } finally {
      release.complete();
    }
  }
}
