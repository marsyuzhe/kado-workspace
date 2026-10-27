import 'dart:math' as math;

import 'package:timezone/timezone.dart' as tz;

import '../../core/data/tool_record.dart';
import 'civil_time.dart';

const recurrenceLabels = {
  'none': '不重复',
  'daily': '每天',
  'weekly': '每周',
  'monthly': '每月',
};

class TimelineRecurrence {
  static DateTime occurrence(
    DateTime anchor,
    int index,
    String zone,
    String rule,
  ) {
    if (index < 0 ||
        index > 150000 ||
        !{'daily', 'weekly', 'monthly'}.contains(rule)) {
      throw const ToolFailure('重复规则或日次无效。');
    }
    final location = CivilTime.location(zone),
        a = tz.TZDateTime.from(anchor, location);
    late DateTime civil;
    if (rule == 'monthly') {
      final month = DateTime.utc(a.year, a.month + index, 1),
          day = math.min(
            a.day,
            DateTime.utc(month.year, month.month + 1, 0).day,
          );
      civil = DateTime.utc(
        month.year,
        month.month,
        day,
        a.hour,
        a.minute,
        a.second,
      );
    } else {
      civil = DateTime.utc(
        a.year,
        a.month,
        a.day + index * (rule == 'weekly' ? 7 : 1),
        a.hour,
        a.minute,
        a.second,
      );
    }
    if (civil.year < 1900 || civil.year > 2200) {
      throw const ToolFailure('下一次待办日期超出1900–2200支持范围。');
    }
    // Keep the original civil anchor. Move a DST gap to its first valid minute.
    for (var minute = 0; minute <= 180; minute++) {
      final v = civil.add(Duration(minutes: minute));
      try {
        return CivilTime.parse(
          '${v.year}-${v.month.toString().padLeft(2, '0')}-${v.day.toString().padLeft(2, '0')} ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}:${v.second.toString().padLeft(2, '0')}',
          zone,
        );
      } on ToolFailure {
        if (minute == 180) rethrow;
      }
    }
    throw const ToolFailure('无法计算下次重复日期。');
  }

  static ({DateTime due, int index, int skipped}) next(
    DateTime anchor,
    int currentIndex,
    String zone,
    String rule,
    DateTime now,
  ) {
    final location = CivilTime.location(zone),
        a = tz.TZDateTime.from(anchor, location),
        n = tz.TZDateTime.from(now, location);
    var index = currentIndex + 1;
    if (rule == 'monthly') {
      index = math.max(index, (n.year - a.year) * 12 + n.month - a.month);
    } else {
      final days = DateTime.utc(
        n.year,
        n.month,
        n.day,
      ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
      index = math.max(index, days ~/ (rule == 'weekly' ? 7 : 1));
    }
    for (var tries = 0; tries < 4; tries++, index++) {
      final due = occurrence(anchor, index, zone, rule);
      if (due.isAfter(now)) {
        return (due: due, index: index, skipped: index - currentIndex - 1);
      }
    }
    throw const ToolFailure('无法计算未来重复日次。');
  }
}
