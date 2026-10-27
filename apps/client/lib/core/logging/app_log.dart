import 'dart:developer' as developer;

enum AppEvent {
  started,
  initializationFailed,
  settingsWriteFailed,
  secureStoreFailed,
  backupFailed,
  frameworkError,
  asynchronousError,
}

/// Only enumerated events and exception TYPE are logged; no free-form values.
class AppLog {
  static void record(AppEvent event, [Object? error]) {
    developer.log(
      '${event.name}${error == null ? '' : ' (${error.runtimeType})'}',
      name: 'links_toolbox',
    );
  }
}
