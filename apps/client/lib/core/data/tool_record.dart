import 'dart:convert';
import 'dart:math';

import '../database/app_database.dart';

String newId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class ToolFailure implements Exception {
  const ToolFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class RecordConflict extends ToolFailure {
  const RecordConflict() : super('记录已在另一个操作中更新。请重新加载，原有内容没有被覆盖。');
}

class ToolRecord {
  const ToolRecord({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.data,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    required this.deviceId,
    this.deletedAt,
    this.syncStatus = 'localOnly',
  });
  factory ToolRecord.fromRow(LocalRecord r) => ToolRecord(
    id: r.id,
    kind: r.kind,
    title: r.title,
    body: r.body,
    data: Map.unmodifiable(jsonDecode(r.data) as Map<String, dynamic>),
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
    revision: r.revision,
    deviceId: r.deviceId,
    deletedAt: r.deletedAt,
    syncStatus: r.syncStatus,
  );
  final String id, kind, title, body, deviceId, syncStatus;
  final Map<String, dynamic> data;
  final DateTime createdAt, updatedAt;
  final DateTime? deletedAt;
  final int revision;
  String text(String key, [String fallback = '']) =>
      data[key] is String ? data[key] as String : fallback;
  bool flag(String key) => data[key] == true;
  int number(String key, [int fallback = 0]) =>
      data[key] is num ? (data[key] as num).toInt() : fallback;
  List<String> strings(String key) =>
      (data[key] is List
              ? (data[key] as List).whereType<String>()
              : const <String>[])
          .toList();
  ToolRecord copyWith({
    String? title,
    String? body,
    Map<String, dynamic>? data,
  }) => ToolRecord(
    id: id,
    kind: kind,
    title: title ?? this.title,
    body: body ?? this.body,
    data: data ?? this.data,
    createdAt: createdAt,
    updatedAt: updatedAt,
    revision: revision,
    deviceId: deviceId,
    deletedAt: deletedAt,
    syncStatus: syncStatus,
  );
}
