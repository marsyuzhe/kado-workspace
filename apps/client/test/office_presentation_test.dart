import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/record_store.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/core/database/app_database.dart';
import 'package:links_toolbox/features/studio/office_domain.dart';
import 'package:links_toolbox/features/studio/office_presentation.dart';
import 'package:links_toolbox/features/studio/studio_repository.dart';

void main() {
  test(
    'system lighting follows local hour boundaries and explicit overrides',
    () {
      for (final pair in {
        0: OfficeEnvironment.night,
        5: OfficeEnvironment.night,
        6: OfficeEnvironment.day,
        16: OfficeEnvironment.day,
        17: OfficeEnvironment.evening,
        20: OfficeEnvironment.evening,
        21: OfficeEnvironment.night,
      }.entries) {
        final now = DateTime(2026, 10, 23, pair.key);
        expect(OfficeEnvironment.system.at(now), pair.value);
        expect(OfficeEnvironment.day.at(now), OfficeEnvironment.day);
      }
    },
  );
  test('versioned presentation bounds camera and recovers corrupt optional settings', () {
    expect(OfficePresentation.decode('broken').zoom, 1);
    expect(
      OfficePresentation.decode('{"version":99}').environment,
      OfficeEnvironment.system,
    );
    final bounded = OfficePresentation.decode(
      '{"version":1,"zoom":10,"x":-5,"y":900,"environment":"night"}',
    );
    expect(bounded.zoom, 4);
    expect(bounded.cameraX, 0);
    expect(bounded.cameraY, 448);
    expect(
      OfficePresentation.decode(bounded.encode()).environment,
      OfficeEnvironment.night,
    );
  });
  test('walking transitions through sit before actual work; stopped tasks never type', () {
    final c = ActorAnimationController();
    String tick({
      bool walking = false,
      bool atDesk = true,
      TaskState? task = TaskState.working,
      bool departing = false,
    }) => c.update(
      dt: .1,
      walking: walking,
      facing: 'up',
      task: task,
      atDesk: atDesk,
      departing: departing,
    );
    expect(
      tick(walking: true, atDesk: false, task: TaskState.walking),
      'walk_up',
    );
    expect(tick(), 'sit');
    for (var i = 0; i < 5; i++) {
      tick();
    }
    expect(c.action, 'typing');
    expect(tick(task: TaskState.waitingApproval), 'waiting');
    expect(tick(task: TaskState.completed), 'success');
    for (var i = 0; i < 30; i++) {
      tick(task: TaskState.completed);
    }
    expect(c.action, 'rest');
    expect(
      tick(
        departing: true,
        walking: true,
        atDesk: false,
        task: TaskState.walking,
      ),
      'stand',
    );
    expect(
      tick(walking: true, atDesk: false, task: TaskState.walking),
      'walk_up',
    );
    expect(tick(atDesk: false, task: TaskState.failed), 'error');
  });
  test('paths cannot cut through reserved chairs and other agents cannot occupy them', () async {
    final layout = OfficeLayout.defaults()..validate();
    final chair = layout.desk('byte')!.seat;
    final route = layout.grid.path(
      Cell(chair.x - 1, chair.y),
      Cell(chair.x + 1, chair.y),
    )!;
    expect(route, isNot(contains(chair)));
    final movement = MovementController(layout, instant: true);
    await expectLater(
      movement.move('links', chair),
      throwsA(isA<ToolFailure>()),
    );
    await movement.move('byte', chair);
    expect(movement.actors['byte']!.seated, isTrue);
    movement.dispose();
  });
  test('seated departure holds feet for stand transition then completes real movement', () async {
    final movement = MovementController(OfficeLayout.defaults());
    final a = movement.actors['byte']!;
    final chair = movement.layout.desk('byte')!.seat;
    a.x = chair.x * 32 + 16;
    a.y = chair.y * 32 + 28;
    a.seated = true;
    final startX = a.x, startY = a.y;
    final done = movement.move('byte', Cell(chair.x, chair.y + 1));
    movement.update(.05);
    expect(a.x, startX);
    expect(a.y, startY);
    expect(a.departureSeconds, greaterThan(0));
    for (var i = 0; i < 40; i++) {
      movement.update(.05);
    }
    await done;
    expect(a.walking, isFalse);
    expect(a.seated, isFalse);
    movement.dispose();
  });
  test(
    'presentation and preexisting layout/notes survive a real database reopen',
    () async {
      final temp = await Directory.systemTemp.createTemp('lt-office-settings-');
      final file = File('${temp.path}/fixture.sqlite');
      var db = AppDatabase.file(file);
      try {
        await db.initialize();
        var store = RecordStore(db);
        final note = await store.create('note', '旧笔记', body: '保留资料');
        final repo = StudioRepository(store);
        await repo.initialize();
        final layout = (await repo.layout()).toJson();
        await store.setSetting(
          'studio.presentation',
          const OfficePresentation(
            environment: OfficeEnvironment.night,
            zoom: 2,
            cameraX: 200,
          ).encode(),
        );
        await db.close();
        db = AppDatabase.file(file);
        await db.initialize();
        store = RecordStore(db);
        expect((await store.get(note.id))!.body, '保留资料');
        expect((await StudioRepository(store).layout()).toJson(), layout);
        expect(
          OfficePresentation.decode(await store.setting('studio.presentation'))
              .zoom,
          2,
        );
        expect(db.schemaVersion, 3);
      } finally {
        await db.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
