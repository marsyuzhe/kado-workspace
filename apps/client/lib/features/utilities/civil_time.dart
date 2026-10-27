import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

import '../../core/data/tool_record.dart';

class CivilTime {
  static bool _ready = false;
  static void initialize() {
    if (!_ready) {
      data.initializeTimeZones();
      _ready = true;
    }
  }

  static tz.Location location(String zone) {
    initialize();
    try {
      return tz.getLocation(zone);
    } catch (_) {
      throw const ToolFailure('IANA时区无效，例如Asia/Shanghai。');
    }
  }

  static DateTime parse(
    String input,
    String zone, {
    bool excel = false,
    bool date1904 = false,
  }) {
    var value = input.trim();
    if (excel && RegExp(r'^\d{1,5}(\.\d+)?$').hasMatch(value)) {
      final serial = double.parse(value);
      if (serial > 110000) {
        throw const ToolFailure('Excel日期序列超出支持范围。');
      }
      final epoch = date1904
          ? DateTime.utc(1904)
          : DateTime.utc(1899, 12, serial < 60 ? 31 : 30);
      final civil = epoch.add(
        Duration(milliseconds: (serial * 86400000).round()),
      );
      value =
          '${civil.year.toString().padLeft(4, '0')}-${civil.month.toString().padLeft(2, '0')}-${civil.day.toString().padLeft(2, '0')} ${civil.hour.toString().padLeft(2, '0')}:${civil.minute.toString().padLeft(2, '0')}:${civil.second.toString().padLeft(2, '0')}';
    }
    final m = RegExp(
      r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
    ).firstMatch(value);
    if (m == null) {
      throw const ToolFailure('日期请使用YYYY-MM-DD HH:MM[:SS]，按所选时区解释。');
    }
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m[i] ?? '0')];
    if (parts[0] < 1900 ||
        parts[0] > 2200 ||
        parts[3] > 23 ||
        parts[4] > 59 ||
        parts[5] > 59) {
      throw const ToolFailure('日期或时间超出支持范围。');
    }
    final result = tz.TZDateTime(
      location(zone),
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (result.year != parts[0] ||
        result.month != parts[1] ||
        result.day != parts[2] ||
        result.hour != parts[3] ||
        result.minute != parts[4] ||
        result.second != parts[5]) {
      throw const ToolFailure('日期不存在，或落在该时区夏令时跳过的时间。');
    }
    return result.toUtc();
  }

  static String format(DateTime instant, String zone, {bool seconds = true}) {
    final d = tz.TZDateTime.from(instant, location(zone));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}${seconds ? ':${two(d.second)}' : ''}';
  }
}
