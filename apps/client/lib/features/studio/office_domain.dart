import 'dart:async';
import 'dart:math' as math;

import '../../core/data/tool_record.dart';

enum AgentState {
  offline,
  idle,
  walking,
  interacting,
  queued,
  working,
  waitingInput,
  waitingApproval,
  paused,
  completed,
  failed,
  cancelled,
}

enum TaskState {
  queued,
  walking,
  working,
  waitingApproval,
  completed,
  failed,
  cancelled,
}

extension TaskStateLabel on TaskState {
  String get label => switch (this) {
    TaskState.queued => '待处理',
    TaskState.walking => '前往工位',
    TaskState.working => '执行中',
    TaskState.waitingApproval => '待审核',
    TaskState.completed => '已完成',
    TaskState.failed => '失败',
    TaskState.cancelled => '已取消',
  };
  bool get terminal => {
    TaskState.completed,
    TaskState.failed,
    TaskState.cancelled,
  }.contains(this);
}

const taskTransitions = <TaskState, Set<TaskState>>{
  TaskState.queued: {TaskState.walking, TaskState.cancelled, TaskState.failed},
  TaskState.walking: {TaskState.working, TaskState.cancelled, TaskState.failed},
  TaskState.working: {
    TaskState.waitingApproval,
    TaskState.cancelled,
    TaskState.failed,
  },
  TaskState.waitingApproval: {TaskState.completed, TaskState.cancelled},
  TaskState.completed: {},
  TaskState.failed: {},
  TaskState.cancelled: {},
};

TaskState taskState(ToolRecord task) =>
    TaskState.values.byName(task.text('status', 'queued'));

class Cell {
  const Cell(this.x, this.y);
  final int x, y;
  int distance(Cell other) => (x - other.x).abs() + (y - other.y).abs();
  Map<String, int> toJson() => {'x': x, 'y': y};
  factory Cell.fromJson(Map data) =>
      Cell((data['x'] as num).toInt(), (data['y'] as num).toInt());
  @override
  bool operator ==(Object other) =>
      other is Cell && x == other.x && y == other.y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => '$x,$y';
}

class Furniture {
  const Furniture(
    this.id,
    this.type,
    this.cell, {
    this.agentId = '',
    this.projectId = '',
  });
  final String id, type, agentId, projectId;
  final Cell cell;
  int get width => 3;
  int get height => type == 'desk' ? 1 : 2;
  Cell get seat => Cell(cell.x + 1, cell.y + 1);
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    ...cell.toJson(),
    'agentId': agentId,
    'projectId': projectId,
    'facing': 'up',
  };
  factory Furniture.fromJson(Map data) => Furniture(
    data['id'] as String,
    data['type'] as String,
    Cell.fromJson(data),
    agentId: data['agentId'] as String? ?? '',
    projectId: data['projectId'] as String? ?? '',
  );
}

const agentNames = ['links', 'byte', 'nova', 'ink', 'pix', 'patch'];
const agentRoles = ['工作室主人', '程序开发', '知识研究', '写作创作', '视觉设计', '测试审查'];
const defaultDesks = [
  Cell(2, 3),
  Cell(7, 3),
  Cell(12, 3),
  Cell(2, 6),
  Cell(7, 6),
  Cell(12, 6),
];

class OfficeLayout {
  OfficeLayout(this.furniture);
  final List<Furniture> furniture;
  static const version = 1;
  static const entrance = Cell(10, 12);
  factory OfficeLayout.defaults() => OfficeLayout([
    for (var i = 0; i < 6; i++)
      Furniture('desk-$i', 'desk', defaultDesks[i], agentId: agentNames[i]),
    const Furniture('meeting', 'meeting', Cell(14, 10)),
    const Furniture('sofa', 'sofa', Cell(2, 10)),
    const Furniture('coffee', 'coffee', Cell(6, 10)),
    const Furniture('shelf', 'shelf', Cell(16, 6)),
    const Furniture('plant-1', 'plant', Cell(16, 3)),
    const Furniture('plant-2', 'plant', Cell(1, 8)),
  ]);
  Map<String, dynamic> toJson() => {
    'payloadVersion': version,
    'tileMapVersion': 1,
    'name': 'Links 夜间工作室',
    'furnitureInstances': furniture.map((f) => f.toJson()).toList(),
    'spawnPoints': {'links': entrance.toJson()},
  };
  factory OfficeLayout.fromJson(Map<String, dynamic> data) {
    if (data['payloadVersion'] != version || data['tileMapVersion'] != 1) {
      throw const ToolFailure('办公室布局版本不兼容，原记录保留。');
    }
    return OfficeLayout(
      (data['furnitureInstances'] as List)
          .map((e) => Furniture.fromJson(e as Map))
          .toList(),
    );
  }
  WalkableGrid get grid => WalkableGrid(this);
  Set<Cell> get seats =>
      furniture.where((f) => f.type == 'desk').map((f) => f.seat).toSet();
  Furniture? desk(String agent) {
    for (final item in furniture) {
      if (item.type == 'desk' && item.agentId == agent) return item;
    }
    return null;
  }

  void validate() {
    final occupied = <Cell>{};
    for (final f in furniture) {
      if (!{
        'desk',
        'plant',
        'shelf',
        'coffee',
        'meeting',
        'sofa',
      }.contains(f.type)) {
        throw const ToolFailure('未知家具类型。');
      }
      for (var y = f.cell.y; y < f.cell.y + f.height; y++) {
        for (var x = f.cell.x; x < f.cell.x + f.width; x++) {
          final c = Cell(x, y);
          if (x < 1 ||
              x >= 19 ||
              y < 2 ||
              y >= 13 ||
              c == entrance ||
              !occupied.add(c)) {
            throw const ToolFailure('家具越界、重叠或挡住入口。');
          }
        }
      }
    }
    final assigned = <String>{};
    for (final f in furniture.where((f) => f.type == 'desk')) {
      if (f.seat == entrance) throw const ToolFailure('椅子不能挡住办公室入口。');
      if (f.agentId.isNotEmpty &&
          (!agentNames.contains(f.agentId) || !assigned.add(f.agentId))) {
        throw const ToolFailure('角色只能分配一个工位。');
      }
      if (grid.path(entrance, f.seat) == null) {
        throw const ToolFailure('布局阻挡了入口到工位的通路。');
      }
    }
  }
}

class WalkableGrid {
  WalkableGrid(OfficeLayout layout) {
    seats.addAll(layout.seats);
    for (final f in layout.furniture) {
      for (var y = f.cell.y; y < f.cell.y + f.height; y++) {
        for (var x = f.cell.x; x < f.cell.x + f.width; x++) {
          blocked.add(Cell(x, y));
        }
      }
    }
  }
  final Set<Cell> blocked = {};
  final Set<Cell> seats = {};
  bool canWalk(Cell c) =>
      c.x >= 1 && c.x < 19 && c.y >= 2 && c.y < 13 && !blocked.contains(c);
  List<Cell>? path(Cell start, Cell goal) {
    if (!canWalk(start) || !canWalk(goal)) return null;
    final open = <Cell>{start},
        came = <Cell, Cell>{},
        g = <Cell, int>{start: 0};
    while (open.isNotEmpty) {
      final current = open.reduce(
        (a, b) =>
            (g[a]! + a.distance(goal)) <= (g[b]! + b.distance(goal)) ? a : b,
      );
      if (current == goal) {
        final result = <Cell>[goal];
        var cursor = goal;
        while (came.containsKey(cursor)) {
          cursor = came[cursor]!;
          result.add(cursor);
        }
        return result.reversed.toList();
      }
      open.remove(current);
      for (final next in [
        Cell(current.x + 1, current.y),
        Cell(current.x - 1, current.y),
        Cell(current.x, current.y + 1),
        Cell(current.x, current.y - 1),
      ]) {
        // A chair is an interaction destination, never a through-route.
        if (!canWalk(next) || (seats.contains(next) && next != goal)) continue;
        final score = g[current]! + 1;
        if (score < (g[next] ?? 100000)) {
          came[next] = current;
          g[next] = score;
          open.add(next);
        }
      }
    }
    return null;
  }
}

class ActorMotion {
  ActorMotion(Cell cell) : x = cell.x * 32 + 16, y = cell.y * 32 + 28;
  double x, y;
  String facing = 'down';
  List<Cell> route = [];
  Completer<void>? completion;
  bool seated = false;
  double departureSeconds = 0;
  bool get walking => route.isNotEmpty;
  Cell get cell => Cell((x / 32).floor(), (y / 32).floor());
}

/// Movement is application state, independent of widgets and the render loop.
/// A timer exists only while walking. Database writes occur at destinations.
class MovementController {
  MovementController(this.layout, {this.instant = false}) {
    for (var i = 0; i < agentNames.length; i++) {
      actors[agentNames[i]] = ActorMotion(
        i == 0 ? OfficeLayout.entrance : Cell(3 + i * 2, 9),
      );
    }
  }
  OfficeLayout layout;
  final bool instant;
  final Map<String, ActorMotion> actors = {};
  Timer? _timer;
  bool _disposed = false;
  Future<void> move(String id, Cell target) async {
    if (_disposed) throw const ToolFailure('办公室已关闭。');
    final actor = actors[id]!;
    if (actor.walking) throw const ToolFailure('角色正在移动，请等待到达。');
    if (layout.seats.contains(target) && layout.desk(id)?.seat != target) {
      throw const ToolFailure('该椅子是其他角色的工位，请选择走道空地。');
    }
    final route = layout.grid.path(actor.cell, target);
    if (route == null) throw const ToolFailure('目标不可达：请点击走道空地。');
    if (instant || route.length < 2) {
      actor.x = target.x * 32 + 16;
      actor.y = target.y * 32 + 28;
      actor.seated = layout.desk(id)?.seat == target;
      return;
    }
    actor.departureSeconds = actor.seated ? .35 : 0;
    actor.seated = false;
    actor.route = route.skip(1).toList();
    actor.completion = Completer<void>();
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => update(.016),
    );
    await actor.completion!.future;
  }

  void stop(String id) {
    final actor = actors[id]!;
    actor.route.clear();
    if (actor.completion case final c? when !c.isCompleted) {
      c.completeError(const ToolFailure('移动已取消。'));
    }
    actor.completion = null;
  }

  void update(double dt) {
    for (final a in actors.values.where((a) => a.walking)) {
      if (a.departureSeconds > 0) {
        a.departureSeconds = (a.departureSeconds - dt.clamp(0, .05)).clamp(
          0,
          .35,
        );
        continue;
      }
      final target = a.route.first;
      final dx = target.x * 32 + 16 - a.x, dy = target.y * 32 + 28 - a.y;
      a.facing = dx.abs() > dy.abs()
          ? (dx > 0 ? 'right' : 'left')
          : (dy > 0 ? 'down' : 'up');
      final distance = math.sqrt(dx * dx + dy * dy),
          step = 80 * dt.clamp(0, .05);
      if (distance <= step) {
        a.x = target.x * 32 + 16;
        a.y = target.y * 32 + 28;
        a.route.removeAt(0);
      } else {
        a.x += dx / distance * step;
        a.y += dy / distance * step;
      }
      if (!a.walking) {
        final id = actors.entries.firstWhere((e) => identical(e.value, a)).key;
        a.seated = layout.desk(id)?.seat == a.cell;
        a.completion?.complete();
        a.completion = null;
      }
    }
    if (!actors.values.any((a) => a.walking)) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final id in actors.keys) {
      stop(id);
    }
  }
}
