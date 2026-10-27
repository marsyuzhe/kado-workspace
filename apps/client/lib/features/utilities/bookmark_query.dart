import 'package:drift/drift.dart';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';

Future<List<ToolRecord>> searchLocalBookmarks(
  RecordStore store,
  String query,
) async {
  final rows = await store.db
      .customSelect(
        "SELECT * FROM local_records WHERE kind='favorite' AND deleted_at IS NULL AND json_extract(data,'\$.action.type')='url' AND instr(lower(title||char(10)||body||char(10)||COALESCE(json_extract(data,'\$.action.target'),'')||char(10)||COALESCE(json_extract(data,'\$.tags'),'')||char(10)||COALESCE(json_extract(data,'\$.category'),'')),lower(?))>0 ORDER BY updated_at DESC LIMIT 101",
        variables: [Variable(query)],
        readsFrom: {store.db.localRecords},
      )
      .get();
  return rows
      .map((r) => ToolRecord.fromRow(store.db.localRecords.map(r.data)))
      .toList();
}
