import 'dart:ui' hide TextStyle;
import 'dart:math' as math;

import 'package:flame/cache.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart' show Colors, TextStyle;

import 'agent_runtime.dart';
import 'office_domain.dart';
import 'office_presentation.dart';

const animationTags = actorAnimationTags;

class OfficeGame extends FlameGame {
  OfficeGame(
    this.runtime, {
    required this.onSelect,
    required this.onGround,
    required this.onFurniture,
  }) : super(
         camera: CameraComponent.withFixedResolution(width: 640, height: 448),
       );
  final AgentRuntime runtime;
  final void Function(String) onSelect;
  final void Function(Cell) onGround;
  final void Function(Furniture) onFurniture;
  final studioImages = Images(prefix: 'assets/pixel_studio/');
  final Map<String, PixelActor> actors = {};
  String selectedId = 'byte';
  final Map<String, String> actorNames = {};
  int assetLoadMs = 0;
  final List<double> _frameSeconds = [];
  void resetPerformanceSamples() => _frameSeconds.clear();
  Map<String, dynamic> get performanceSnapshot => {
    'assetLoadMs': assetLoadMs,
    'samples': _frameSeconds.length,
    'sceneUpdateFps': _frameSeconds.isEmpty
        ? null
        : _frameSeconds.length / _frameSeconds.reduce((a, b) => a + b),
    'measurement': 'visible Flame update dt; integration test pumping is not a device benchmark',
  };
  bool showGrid = false;
  @override
  Color backgroundColor() => const Color(0xff101521);
  @override
  Future<void> onLoad() async {
    final watch = Stopwatch()..start();
    camera.viewfinder.position = Vector2(
      runtime.presentation.cameraX,
      runtime.presentation.cameraY,
    );
    camera.viewfinder.zoom = runtime.presentation.zoom;
    final floor = Sprite(await studioImages.load('rooms/office_shell.png'));
    await world.add(_Floor(this, floor));
    for (final f in runtime.movement.layout.furniture) {
      final sprite = Sprite(await studioImages.load('furniture/${f.type}.png'));
      await world.add(
        SpriteComponent(
          sprite: sprite,
          position: Vector2(f.cell.x * 32, f.cell.y * 32 - 16),
          size: Vector2.all(96),
          priority: f.cell.y * 32 + 26,
          paint: Paint()..filterQuality = FilterQuality.none,
        ),
      );
    }
    for (final id in agentNames) {
      final sheet = await studioImages.load('characters/$id.png');
      final animations = <String, SpriteAnimation>{};
      for (var row = 0; row < animationTags.length; row++) {
        animations[animationTags[row]] = SpriteAnimation.spriteList(
          [
            for (var frame = 0; frame < 8; frame++)
              Sprite(
                sheet,
                srcPosition: Vector2(frame * 32, row * 48),
                srcSize: Vector2(32, 48),
              ),
          ],
          stepTime: row >= 1 && row <= 4
              ? 0.1
              : {'sit', 'stand'}.contains(animationTags[row])
              ? .05
              : .16,
          loop: !{'sit', 'stand'}.contains(animationTags[row]),
        );
      }
      final actor = PixelActor(this, id, animations);
      actors[id] = actor;
      await world.add(actor);
    }
    await world.add(_Grid(this));
    await world.add(_Environment(this));
    assetLoadMs = watch.elapsedMilliseconds;
  }

  @override
  void update(double dt) {
    if (dt > 0 && dt < 1) {
      _frameSeconds.add(dt);
      if (_frameSeconds.length > 300) _frameSeconds.removeAt(0);
    }
    super.update(dt);
  }

  String? actorAt(Offset canvasPoint) {
    final point = camera.globalToLocal(Vector2(canvasPoint.dx, canvasPoint.dy));
    final sorted = actors.values.toList()
      ..sort((a, b) => b.priority.compareTo(a.priority));
    for (final actor in sorted) {
      if (Rect.fromLTWH(
        actor.x - 16,
        actor.y - 48,
        32,
        48,
      ).contains(Offset(point.x, point.y))) {
        return actor.id;
      }
    }
    return null;
  }

  Future<void> saveView({OfficeEnvironment? environment}) =>
      runtime.savePresentation(
        OfficePresentation(
          environment: environment ?? runtime.presentation.environment,
          zoom: camera.viewfinder.zoom.roundToDouble(),
          cameraX: camera.viewfinder.position.x,
          cameraY: camera.viewfinder.position.y,
        ),
      );

  void zoomBy(double factor) {
    camera.viewfinder.zoom = (camera.viewfinder.zoom * factor).clamp(1, 4);
  }

  void snapZoom() {
    camera.viewfinder.zoom = camera.viewfinder.zoom.roundToDouble().clamp(1, 4);
  }

  void pan(Offset delta) {
    final p = camera.viewfinder.position;
    final scale = camera.viewfinder.zoom * camera.viewport.size.x / 640;
    camera.viewfinder.position = Vector2(
      (p.x - delta.dx / scale).clamp(0, 640),
      (p.y - delta.dy / scale).clamp(0, 448),
    );
  }

  void overview() {
    camera.viewfinder.zoom = 1;
    camera.viewfinder.position = Vector2(320, 224);
  }

  void focusActor(String id) {
    final motion = runtime.movement.actors[id];
    if (motion != null) {
      camera.viewfinder.position = Vector2(motion.x, motion.y - 16);
      camera.viewfinder.zoom = 2;
    }
  }

  /// Widget detachment is temporary during responsive reparenting/tab changes.
  /// Only the owning page may release these textures after its last frame.
  void releaseAssets() {
    pauseEngine();
    studioImages.clearCache();
  }
}

class _Floor extends SpriteComponent with TapCallbacks {
  _Floor(this.office, Sprite sprite)
    : super(
        sprite: sprite,
        size: Vector2(640, 448),
        paint: Paint()..filterQuality = FilterQuality.none,
        priority: -100,
      );
  final OfficeGame office;
  @override
  void onTapDown(TapDownEvent event) {
    final cell = Cell(
      (event.localPosition.x / 32).floor(),
      (event.localPosition.y / 32).floor(),
    );
    for (final f in office.runtime.movement.layout.furniture) {
      if (cell.x >= f.cell.x &&
          cell.x < f.cell.x + f.width &&
          cell.y >= f.cell.y &&
          cell.y < f.cell.y + f.height) {
        office.onFurniture(f);
        return;
      }
    }
    office.onGround(cell);
  }
}

class PixelActor extends SpriteAnimationGroupComponent<String>
    with TapCallbacks, HoverCallbacks {
  PixelActor(this.office, this.id, Map<String, SpriteAnimation> animations)
    : super(
        animations: animations,
        current: 'idle',
        size: Vector2(32, 48),
        anchor: Anchor.bottomCenter,
        paint: Paint()..filterQuality = FilterQuality.none,
      );
  final OfficeGame office;
  final String id;
  final controller = ActorAnimationController();
  final labelPaint = TextPaint(
    style: const TextStyle(fontSize: 8, color: Color(0xffd7deeb)),
  );
  @override
  void onTapDown(TapDownEvent event) => office.onSelect(id);
  @override
  void update(double dt) {
    final motion = office.runtime.movement.actors[id]!;
    position.setValues(motion.x.roundToDouble(), motion.y.roundToDouble());
    priority = motion.y.floor();
    var eventState = office.runtime.activeStates[id];
    final changed = office.runtime.stateChangedAt[id];
    if (eventState?.terminal == true &&
        changed != null &&
        DateTime.now().difference(changed).inSeconds >= 5) {
      eventState = null;
    }
    final action = controller.update(
      dt: dt,
      walking: motion.walking,
      departing: motion.departureSeconds > 0,
      facing: motion.facing,
      task: eventState,
      atDesk: motion.seated,
      workAction: id == 'nova' ? 'reading' : 'typing',
    );
    if (current != action) current = action;
    super.update(dt);
  }

  @override
  void render(Canvas canvas) {
    if (office.selectedId == id || isHovered) {
      canvas.drawOval(
        const Rect.fromLTWH(1, 39, 30, 8),
        Paint()
          ..color = const Color(0xffd3be95)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    super.render(canvas);
    labelPaint.render(
      canvas,
      office.actorNames[id] ??
          (id == 'links'
              ? 'Links'
              : '${id[0].toUpperCase()}${id.substring(1)}'),
      Vector2(16, -8),
      anchor: Anchor.bottomCenter,
    );
    final state = office.runtime.activeStates[id];
    if (state == TaskState.working || state == TaskState.waitingApproval) {
      canvas.drawRect(
        const Rect.fromLTWH(27, 4, 4, 4),
        Paint()
          ..color = state == TaskState.working
              ? const Color(0xff8196be)
              : const Color(0xffd3be95),
      );
    }
  }
}

/// Hard-edged pixel lighting and ambient details; no task progress is invented.
class _Environment extends Component {
  _Environment(this.office) : super(priority: 9000);
  final OfficeGame office;
  double elapsed = 0;
  DateTime localTime = DateTime.now();
  @override
  void update(double dt) {
    elapsed += dt;
    if (elapsed >= 1) {
      localTime = DateTime.now();
      elapsed %= 1;
    }
  }

  @override
  void render(Canvas canvas) {
    final mode = office.runtime.presentation.environment.at(localTime);
    final tint = switch (mode) {
      OfficeEnvironment.day => const Color(0x16fff1d1),
      OfficeEnvironment.evening => const Color(0x25b67649),
      _ => const Color(0x60050c21),
    };
    canvas.drawRect(
      const Rect.fromLTWH(18, 15, 604, 415),
      Paint()..color = tint,
    );
    final sky = switch (mode) {
      OfficeEnvironment.day => const Color(0xff99afbf),
      OfficeEnvironment.evening => const Color(0xff957b87),
      _ => const Color(0xff23334e),
    };
    for (final x in [58.0, 248.0, 438.0]) {
      canvas.drawRect(Rect.fromLTWH(x + 5, 27, 102, 23), Paint()..color = sky);
      for (var b = 0; b < 9; b++) {
        final height = 5.0 + (b * 7 % 13);
        canvas.drawRect(
          Rect.fromLTWH(x + 7 + b * 11, 50 - height, 8, height),
          Paint()
            ..color = mode == OfficeEnvironment.day
                ? const Color(0xff708697)
                : const Color(0xff38445b),
        );
        if (mode == OfficeEnvironment.night) {
          canvas.drawRect(
            Rect.fromLTWH(x + 9 + b * 11, 46 - height, 2, 2),
            Paint()..color = const Color(0xffd0b886),
          );
        }
      }
      canvas.drawRect(
        Rect.fromLTWH(x + 56, 25, 4, 28),
        Paint()..color = const Color(0xffa6aaa9),
      );
    }
    for (final f in office.runtime.movement.layout.furniture.where(
      (f) => f.type == 'desk',
    )) {
      final left = f.cell.x * 32.0, top = f.cell.y * 32.0 - 16;
      canvas.drawRect(
        Rect.fromLTWH(left + 33, top + 5, 30, 15),
        Paint()..color = const Color(0xff526d8d),
      );
      final working =
          office.runtime.activeStates[f.agentId] == TaskState.working;
      for (var line = 0; line < 3; line++) {
        final shift = working ? (localTime.second % 4) * 2.0 : 0.0;
        canvas.drawRect(
          Rect.fromLTWH(
            left + 36,
            top + 7 + line * 4,
            12 + ((line * 7 + shift) % 12),
            1,
          ),
          Paint()..color = const Color(0xffb0c0d0),
        );
      }
      if (mode != OfficeEnvironment.day) {
        canvas.drawRect(
          Rect.fromLTWH(left + 20, top + 20, 12, 3),
          Paint()..color = const Color(0xffe2c18b),
        );
      }
    }
    // A real local clock and modest coffee indicator are visual ambience.
    canvas.drawCircle(
      const Offset(211, 38),
      9,
      Paint()..color = const Color(0xff30394d),
    );
    final angle = localTime.minute * math.pi / 30 - math.pi / 2;
    final hour =
        (localTime.hour % 12 + localTime.minute / 60) * math.pi / 6 -
        math.pi / 2;
    canvas.drawLine(
      const Offset(211, 38),
      Offset(211 + math.cos(angle) * 7, 38 + math.sin(angle) * 7),
      Paint()..color = const Color(0xffdbceb0),
    );
    canvas.drawLine(
      const Offset(211, 38),
      Offset(211 + math.cos(hour) * 5, 38 + math.sin(hour) * 5),
      Paint()..color = const Color(0xffdbceb0),
    );
  }
}

class _Grid extends Component {
  _Grid(this.office) : super(priority: 10000);
  final OfficeGame office;
  @override
  void render(Canvas canvas) {
    if (!office.showGrid) return;
    final grid = office.runtime.movement.layout.grid;
    for (var y = 2; y < 13; y++) {
      for (var x = 1; x < 19; x++) {
        final blocked = !grid.canWalk(Cell(x, y));
        canvas.drawRect(
          Rect.fromLTWH(x * 32, y * 32, 32, 32),
          Paint()
            ..color = (blocked ? Colors.red : Colors.blue).withValues(
              alpha: .18,
            )
            ..style = PaintingStyle.stroke,
        );
      }
    }
    for (final a in office.runtime.movement.actors.values) {
      for (final c in a.route) {
        canvas.drawRect(
          Rect.fromLTWH(c.x * 32 + 14, c.y * 32 + 14, 4, 4),
          Paint()..color = const Color(0xffd3be95),
        );
      }
    }
  }
}
