import 'dart:async';
import 'dart:isolate';

import '../../core/data/tool_record.dart';

void _entry(
  (SendPort, FutureOr<Object?> Function(Object?), Object?) args,
) async {
  try {
    args.$1.send({'value': await args.$2(args.$3)});
  } catch (e) {
    args.$1.send({'error': e.toString()});
  }
}

/// A killable isolate is required for synchronous regex backtracking. A Future
/// timeout alone cannot interrupt it. Inputs/outputs also have feature limits.
class ControlledWorker {
  ControlledWorker(
    FutureOr<Object?> Function(Object?) operation,
    Object? input, {
    Duration timeout = const Duration(seconds: 3),
  }) {
    _subscription = _port.listen((message) {
      if (message is Map && message.containsKey('value')) {
        _complete(message['value']);
      } else {
        _fail(
          ToolFailure(message is Map ? '${message['error']}' : '后台处理意外退出。'),
        );
      }
    });
    _timer = Timer(
      timeout,
      () => _fail(const ToolFailure('处理超时，后台执行已终止。请缩小输入或简化表达式。')),
    );
    Isolate.spawn(
      _entry,
      (_port.sendPort, operation, input),
      onExit: _port.sendPort,
      onError: _port.sendPort,
      errorsAreFatal: true,
    ).then(
      (isolate) {
        _isolate = isolate;
        if (_result.isCompleted) isolate.kill(priority: Isolate.immediate);
      },
      onError: (Object e, StackTrace s) =>
          _fail(const ToolFailure('无法启动后台处理。')),
    );
  }
  final _port = ReceivePort();
  final _result = Completer<Object?>();
  late final StreamSubscription<dynamic> _subscription;
  late final Timer _timer;
  Isolate? _isolate;
  Future<Object?> get result => _result.future;
  void _close() {
    _timer.cancel();
    _isolate?.kill(priority: Isolate.immediate);
    unawaited(_subscription.cancel());
    _port.close();
  }

  void _complete(Object? value) {
    if (_result.isCompleted) return;
    _result.complete(value);
    _close();
  }

  void _fail(Object error) {
    if (_result.isCompleted) return;
    _result.completeError(error);
    _close();
  }

  void cancel() => _fail(const ToolFailure('处理已取消。'));
}
