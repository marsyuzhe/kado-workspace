import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as arc;
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/data/tool_record.dart';
import 'package:links_toolbox/features/utilities/bill_reader.dart';
import 'package:links_toolbox/features/utilities/money.dart';

Uint8List billXlsx({
  bool date1904 = false,
  String target = 'worksheets/sheet1.xml',
  String? specialXml,
}) {
  final files = <String, String>{
    '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
    '_rels/.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="root" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml':
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr date1904="${date1904 ? 1 : 0}"/><sheets><sheet name="脱敏账单" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="$target"/></Relationships>',
    'xl/sharedStrings.xml': '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>交易时间</t></si><si><t>金额(元)</t></si><si><t>交易单号</t></si></sst>',
    'xl/worksheets/sheet1.xml': specialXml ?? '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c><c r="D1" t="s"><v>2</v></c></row><row r="2"><c r="A2"><v>45292.5</v></c><c r="C2"><v>1.23E+2</v></c><c r="D2" t="inlineStr"><is><t>00012345678901234567890</t></is></c></row></sheetData></worksheet>',
  };
  final archive = arc.Archive();
  for (final item in files.entries) {
    archive.addFile(arc.ArchiveFile.string(item.key, item.value));
  }
  return Uint8List.fromList(arc.ZipEncoder().encode(archive));
}

void main() {
  test('money retains exact decimal minor units, currency precision and scientific XLSX numbers without rounding', () {
    expect(Money.parse('0.10') + Money.parse('0.20'), 30);
    expect(Money.format(30), '0.30');
    expect(Money.parse('¥1,234.50'), 123450);
    expect(Money.parse('1.23E+2'), 12300);
    expect(Money.parse('0.001', currency: 'KWD'), 1);
    expect(Money.format(1, currency: 'KWD'), '0.001');
    expect(Money.parse('100', currency: 'JPY'), 100);
    expect(Money.format(-100, currency: 'JPY'), '-100');
    expect(Money.parse('-12.34', signed: true), -1234);
    for (final value in [
      '0.001',
      'NaN',
      '1e30',
      '12,34',
      '-1.00',
      '9999999999999',
      '1.00000001',
    ]) {
      expect(() => Money.parse(value), throwsA(isA<ToolFailure>()));
    }
    expect(
      () => Money.parse('10.01', currency: 'JPY'),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('CSV UTF8 and UTF16 preserve long order IDs, quoted newlines and raw decimal text', () {
    const source =
        '说明行\n交易时间,交易单号,金额,备注\n2026-10-01,00012345678901234567890,0.10,"两行\n说明"\n';
    final table = BillReader.read(
      Uint8List.fromList(utf8.encode(source)),
      'bill.csv',
    );
    expect(table.rows.last[1], '00012345678901234567890');
    expect(table.rows.last[2], '0.10');
    expect(table.rows.last[3], '两行\n说明');
    final utf16 = <int>[
      0xff,
      0xfe,
      for (final c in source.codeUnits) ...[c & 0xff, c >> 8],
    ];
    expect(
      BillReader.read(Uint8List.fromList(utf16), 'bill.csv').rows,
      table.rows,
    );
    expect(
      () => BillReader.read(Uint8List.fromList([0xd6, 0xd0]), 'bill.csv'),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('explicit GBK decodes an independent Python GBK fixture without guessing or replacement', () {
    const hex =
        'bdbbd2d7cab1bce42ccad52fd6a72cbdf0b6ee28d4aa290a323032362d31302d30312cd6a7b3f62c302e31300a';
    final bytes = Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
    final table = BillReader.read(bytes, 'bill.csv', encoding: 'gbk');
    expect(table.rows.first, ['交易时间', '收/支', '金额(元)']);
    expect(table.rows.last, ['2026-10-01', '支出', '0.10']);
    expect(
      () => BillReader.read(bytes, 'bill.csv'),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => BillReader.read(
        Uint8List.fromList([0x81]),
        'bill.csv',
        encoding: 'gbk',
      ),
      throwsA(isA<ToolFailure>()),
    );
  });
  test('bounded actual XLSX ZIP parses shared/inline strings, sparse columns, serial date metadata and prevents unsafe XML paths', () {
    final table = BillReader.read(billXlsx(), 'bill.xlsx');
    expect(table.sheet, '脱敏账单');
    expect(table.rows.first, ['交易时间', '', '金额(元)', '交易单号']);
    expect(table.rows.last, [
      '45292.5',
      '',
      '1.23E+2',
      '00012345678901234567890',
    ]);
    expect(Money.parse(table.rows.last[2]), 12300);
    expect(
      BillReader.read(billXlsx(date1904: true), 'bill.xlsx').excelDate1904,
      true,
    );
    expect(
      () => BillReader.read(billXlsx(target: '../../outside.xml'), 'bill.xlsx'),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => BillReader.read(
        billXlsx(
          specialXml:
              '<!DOCTYPE x [<!ENTITY e SYSTEM "file:///private">]><worksheet/>',
        ),
        'bill.xlsx',
      ),
      throwsA(isA<ToolFailure>()),
    );
    expect(
      () => BillReader.read(
        billXlsx(
          specialXml: '<worksheet><sheetData><row><c r="A1"><f>1+1</f></c></row></sheetData></worksheet>',
        ),
        'bill.xlsx',
      ),
      throwsA(isA<ToolFailure>()),
    );
  });
}
