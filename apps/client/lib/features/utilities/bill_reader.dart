import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as arc;
import 'package:csv/csv.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../core/data/tool_record.dart';

class BillTable {
  const BillTable(
    this.rows, {
    this.sheets = const [],
    this.sheet = '',
    this.excelDate1904 = false,
    this.xlsx = false,
  });
  final List<List<String>> rows;
  final List<String> sheets;
  final String sheet;
  final bool excelDate1904, xlsx;
}

/// A deliberately bounded XLSX values reader, never an Excel/formula engine.
/// Only workbook relationships, cell values and shared/inline strings are read.
class BillReader {
  static const inputLimit = 10 * 1024 * 1024, xmlLimit = 8 * 1024 * 1024;
  static String text(Uint8List bytes, {String encoding = 'auto'}) {
    try {
      if (encoding == 'gbk') {
        final decoded = gbk.decode(bytes), roundTrip = gbk.encode(decoded);
        if (roundTrip.length != bytes.length) {
          throw const FormatException('GBK is not lossless');
        }
        for (var i = 0; i < bytes.length; i++) {
          if (roundTrip[i] != bytes[i]) {
            throw const FormatException('GBK is not lossless');
          }
        }
        return decoded;
      }
      if (encoding != 'auto') {
        throw const FormatException('Unknown encoding');
      }
      if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
        if (bytes.length.isOdd) {
          throw const FormatException();
        }
        final data = ByteData.sublistView(bytes), units = <int>[];
        for (var i = 2; i < bytes.length; i += 2) {
          units.add(data.getUint16(i, Endian.little));
        }
        return String.fromCharCodes(units);
      }
      return utf8.decode(bytes).replaceFirst('\ufeff', '');
    } catch (_) {
      throw const ToolFailure('账单编码不可读。请明确选择GBK编码或另存为UTF-8 CSV；不猜测或替换乱码。');
    }
  }

  static BillTable read(
    Uint8List bytes,
    String name, {
    String? sheet,
    String encoding = 'auto',
  }) {
    if (bytes.isEmpty || bytes.length > inputLimit) {
      throw const ToolFailure('账单输入需为非空、最多10MiB的CSV或XLSX。');
    }
    try {
      if (p.extension(name).toLowerCase() == '.csv') {
        final rows = Csv(dynamicTyping: false)
            .decode(text(bytes, encoding: encoding))
            .map((r) => r.map((c) => c.toString()).toList())
            .toList();
        _bounds(rows);
        return BillTable(rows);
      }
      if (p.extension(name).toLowerCase() != '.xlsx') {
        throw const ToolFailure('仅支持CSV和未加密XLSX。');
      }
      final central = arc.ZipDirectory()..read(arc.InputMemoryStream(bytes));
      final seen = <String>{};
      var expanded = 0;
      if (central.fileHeaders.length > 500) {
        throw const ToolFailure('XLSX包含过多ZIP条目。');
      }
      for (final header in central.fileHeaders) {
        final path = header.filename;
        if (path.contains('\\') ||
            p.posix.isAbsolute(path) ||
            path.split('/').contains('..') ||
            path.contains(':') ||
            !seen.add(path.toLowerCase()) ||
            ((header.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
          throw const ToolFailure('XLSX包含非法或重名ZIP条目。');
        }
        expanded += header.uncompressedSize;
        if (header.uncompressedSize < 0 || expanded > 32 * 1024 * 1024) {
          throw const ToolFailure('XLSX解压大小超过32MiB。');
        }
      }
      final archive = arc.ZipDecoder().decodeBytes(bytes);
      XmlDocument xml(String path) {
        final entry = archive.find(path);
        if (entry == null || !entry.isFile || entry.size > xmlLimit) {
          throw const ToolFailure('XLSX结构缺失或XML超过8MiB。');
        }
        final source = utf8.decode(entry.readBytes()!);
        if (source.contains('<!DOCTYPE') || source.contains('<!ENTITY')) {
          throw const ToolFailure('XLSX不接受DTD或自定义实体。');
        }
        return XmlDocument.parse(source);
      }

      final workbook = xml('xl/workbook.xml'),
          relations = xml('xl/_rels/workbook.xml.rels');
      final sheets = workbook.findAllElements('sheet').toList();
      if (sheets.isEmpty || sheets.length > 50) {
        throw const ToolFailure('XLSX工作表数量无效。');
      }
      final names = sheets.map((s) => s.getAttribute('name') ?? '').toList();
      final chosen = sheet == null
          ? sheets.first
          : sheets.firstWhere(
              (s) => s.getAttribute('name') == sheet,
              orElse: () => throw const ToolFailure('工作表已不存在。'),
            );
      String? id;
      for (final a in chosen.attributes) {
        if (a.name.local == 'id') {
          id = a.value;
        }
      }
      final relationship = relations
          .findAllElements('Relationship')
          .where((r) => r.getAttribute('Id') == id)
          .toList();
      if (id == null ||
          relationship.length != 1 ||
          relationship.single.getAttribute('TargetMode') == 'External') {
        throw const ToolFailure('工作表关系无效或指向外部。');
      }
      final target = relationship.single.getAttribute('Target') ?? '';
      if (target.contains('\\') ||
          target.contains(':') ||
          target.split('/').contains('..')) {
        throw const ToolFailure('工作表路径非法。');
      }
      final path = p.posix.normalize(
        target.startsWith('/') ? target.substring(1) : 'xl/$target',
      );
      if (!path.startsWith('xl/worksheets/') || !path.endsWith('.xml')) {
        throw const ToolFailure('仅支持标准XLSX工作表路径。');
      }
      final shared = <String>[];
      if (archive.find('xl/sharedStrings.xml') != null) {
        for (final si in xml('xl/sharedStrings.xml').findAllElements('si')) {
          shared.add(si.findAllElements('t').map((t) => t.innerText).join());
          if (shared.length > 250000) {
            throw const ToolFailure('XLSX共享文本超限。');
          }
        }
      }
      final rows = <List<String>>[];
      var cells = 0;
      for (final row in xml(path).findAllElements('row')) {
        final values = <int, String>{};
        var next = 0;
        for (final cell in row.findElements('c')) {
          final reference = RegExp(r'^([A-Za-z]+)\d+$')
              .firstMatch(cell.getAttribute('r') ?? '');
          var column = next;
          if (reference != null) {
            column = 0;
            for (final unit in reference[1]!.toUpperCase().codeUnits) {
              column = column * 26 + unit - 64;
            }
            column--;
          }
          if (column < 0 || column >= 64 || values.containsKey(column)) {
            throw const ToolFailure('XLSX超过64列或单元格重复。');
          }
          final type = cell.getAttribute('t'),
              raw = cell.getElement('v')?.innerText ?? '';
          String value;
          if (type == 's') {
            final index = int.tryParse(raw);
            if (index == null || index < 0 || index >= shared.length) {
              throw const ToolFailure('XLSX文本索引无效。');
            }
            value = shared[index];
          } else if (type == 'inlineStr') {
            value = cell.findAllElements('t').map((n) => n.innerText).join();
          } else if (type == 'e') {
            throw const ToolFailure('工作表含错误值，请先修复或导出纯值账单。');
          } else {
            value = raw;
          }
          if (cell.getElement('f') != null && raw.isEmpty) {
            throw const ToolFailure('公式单元格缺少已保存结果；本工具不执行公式。');
          }
          values[column] = value;
          next = column + 1;
          cells++;
          if (cells > 250000) {
            throw const ToolFailure('XLSX单元格总数超限。');
          }
        }
        if (values.isNotEmpty) {
          final width = values.keys.reduce((a, b) => a > b ? a : b) + 1;
          rows.add(List.generate(width, (i) => values[i] ?? ''));
        }
        if (rows.length > 10050) {
          throw const ToolFailure('单次最多10000条交易与少量账单说明行。');
        }
      }
      _bounds(rows);
      final date1904 = workbook
          .findAllElements('workbookPr')
          .any((e) => {'1', 'true'}.contains(e.getAttribute('date1904')));
      return BillTable(
        rows,
        sheets: names,
        sheet: chosen.getAttribute('name') ?? '',
        excelDate1904: date1904,
        xlsx: true,
      );
    } on ToolFailure {
      rethrow;
    } catch (_) {
      throw const ToolFailure('无法解析账单，请检查CSV引号、文件损坏或XLSX加密。');
    }
  }

  static void _bounds(List<List<String>> rows) {
    if (rows.isEmpty ||
        rows.length > 10050 ||
        rows.any((r) => r.length > 64 || r.any((v) => v.length > 20000))) {
      throw const ToolFailure('账单为空或行、列、单元格文本超出安全上限。');
    }
  }
}
