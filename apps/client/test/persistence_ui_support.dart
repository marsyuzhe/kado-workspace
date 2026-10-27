import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Progress both the widget fake frame queue and actual SQLite IO. A Future
/// started by a widget may resume in its original zone even during runAsync.
Future<T> withPersistenceFrames<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  final watch = Stopwatch()..start();
  var completed = false;
  late T result;
  Object? error;
  StackTrace? trace;
  await tester.runAsync(() async {
    unawaited(
      operation().then<void>(
        (value) {
          result = value;
          completed = true;
        },
        onError: (Object e, StackTrace s) {
          error = e;
          trace = s;
          completed = true;
        },
      ),
    );
  });
  while (!completed && watch.elapsed < const Duration(seconds: 10)) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  if (!completed) {
    throw TestFailure(
      'The real UI persistence operation did not complete within 10 seconds.',
    );
  }
  if (error != null) Error.throwWithStackTrace(error!, trace!);
  return result;
}

Future<T> waitForPersisted<T>(
  WidgetTester tester,
  Future<T> Function() read,
  bool Function(T) accepted,
) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 10)) {
    final value = await withPersistenceFrames(tester, read);
    if (accepted(value)) return value;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
  throw TestFailure(
    'The real persisted state did not reach its expected value within 10 seconds.',
  );
}
