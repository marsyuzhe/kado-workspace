import 'dart:convert';

import 'office_domain.dart';

enum OfficeEnvironment { system, day, evening, night }

extension OfficeEnvironmentLabel on OfficeEnvironment {
  String get label => switch (this) {
    OfficeEnvironment.system => '跟随时间',
    OfficeEnvironment.day => '白天',
    OfficeEnvironment.evening => '傍晚',
    OfficeEnvironment.night => '夜间',
  };

  OfficeEnvironment at(DateTime localTime) {
    if (this != OfficeEnvironment.system) return this;
    return switch (localTime.hour) {
      >= 6 && < 17 => OfficeEnvironment.day,
      >= 17 && < 21 => OfficeEnvironment.evening,
      _ => OfficeEnvironment.night,
    };
  }
}

/// Separate versioned presentation settings keep older furniture layouts valid.
class OfficePresentation {
  const OfficePresentation({
    this.environment = OfficeEnvironment.system,
    this.zoom = 1,
    this.cameraX = 320,
    this.cameraY = 224,
  });
  final OfficeEnvironment environment;
  final double zoom, cameraX, cameraY;
  factory OfficePresentation.decode(String? value) {
    if (value == null) return const OfficePresentation();
    try {
      final data = jsonDecode(value) as Map;
      if (data['version'] != 1) return const OfficePresentation();
      double bounded(String key, double fallback, double min, double max) {
        final raw = data[key];
        return raw is num && raw.isFinite
            ? raw.toDouble().clamp(min, max)
            : fallback;
      }

      return OfficePresentation(
        environment:
            OfficeEnvironment.values
                .where((e) => e.name == data['environment'])
                .firstOrNull ??
            OfficeEnvironment.system,
        zoom: bounded('zoom', 1, 1, 4).roundToDouble(),
        cameraX: bounded('x', 320, 0, 640),
        cameraY: bounded('y', 224, 0, 448),
      );
    } catch (_) {
      // Malformed optional UI settings cannot make user tasks inaccessible.
      return const OfficePresentation();
    }
  }
  String encode() => jsonEncode({
    'version': 1,
    'environment': environment.name,
    'zoom': zoom,
    'x': cameraX,
    'y': cameraY,
  });
}

const actorAnimationTags = [
  'idle',
  'walk_up',
  'walk_down',
  'walk_left',
  'walk_right',
  'sit',
  'typing',
  'reading',
  'thinking',
  'talking',
  'waiting',
  'success',
  'error',
  'stand',
  'meeting',
  'rest',
  'deliver',
];

/// A visual state machine only; it never advances or fabricates a task state.
class ActorAnimationController {
  String action = 'idle';
  TaskState? _state;
  double _stateAge = 0;
  double _sitAge = 0;
  bool _wasSeated = false;
  double _standAge = 0;
  String update({
    required double dt,
    required bool walking,
    required String facing,
    required TaskState? task,
    required bool atDesk,
    bool departing = false,
    String workAction = 'typing',
  }) {
    dt = dt.clamp(0, .1);
    if (_state != task) {
      _state = task;
      _stateAge = 0;
    } else {
      _stateAge += dt;
    }
    if (departing) {
      _standAge += dt;
      action = 'stand';
    } else if (walking) {
      _sitAge = 0;
      _wasSeated = false;
      _standAge = 0;
      action = 'walk_$facing';
    } else if (atDesk && task == TaskState.working) {
      _sitAge += dt;
      _wasSeated = true;
      action = _sitAge < .4 ? 'sit' : workAction;
    } else if (_wasSeated && !atDesk && _standAge < .35) {
      _standAge += dt;
      action = 'stand';
    } else {
      action = switch (task) {
        TaskState.queued || TaskState.waitingApproval => 'waiting',
        TaskState.completed when _stateAge < 2.5 => 'success',
        TaskState.failed when _stateAge < 4 => 'error',
        _ => atDesk ? 'rest' : 'idle',
      };
    }
    return action;
  }
}
