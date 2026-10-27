import '../../core/data/tool_record.dart';

/// Exact fixed-point values, never binary floating-point arithmetic for money.
class Money {
  static const currencies = [
    'CNY',
    'USD',
    'EUR',
    'GBP',
    'HKD',
    'TWD',
    'AUD',
    'CAD',
    'SGD',
    'JPY',
    'KRW',
    'KWD',
    'BHD',
    'JOD',
  ];
  static int digits(String currency) => switch (currency) {
    'JPY' || 'KRW' => 0,
    'KWD' || 'BHD' || 'JOD' => 3,
    _ => 2,
  };
  static String currency(String raw) {
    final value = raw.trim().toUpperCase();
    if (!{
      'CNY',
      'USD',
      'EUR',
      'GBP',
      'HKD',
      'TWD',
      'AUD',
      'CAD',
      'SGD',
      'JPY',
      'KRW',
      'KWD',
      'BHD',
      'JOD',
    }.contains(value)) {
      throw const ToolFailure('请选择支持的币种；不同币种分别统计，不自动换汇。');
    }
    return value;
  }

  static int parse(
    String text, {
    String currency = 'CNY',
    bool signed = false,
  }) {
    final code = Money.currency(currency), precision = digits(code);
    var value = text.trim().replaceFirst(RegExp(r'^[¥￥$]'), '').trim();
    if (value.contains(',')) {
      if (!RegExp(r'^[+-]?\d{1,3}(,\d{3})+(\.\d+)?$').hasMatch(value)) {
        throw const ToolFailure('金额的千分位格式无效。');
      }
      value = value.replaceAll(',', '');
    }
    // XLSX numerical <v> cells may use exponent notation. Expand decimal
    // digits as strings, without rounding a double or losing an order ID.
    final scientific = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?[eE]([+-]?\d{1,2})$')
        .firstMatch(value);
    if (scientific != null) {
      final whole = scientific[2]!,
          fraction = scientific[3] ?? '',
          offset = whole.length + int.parse(scientific[4]!);
      if (offset.abs() > 18) {
        throw const ToolFailure('金额数量级超限。');
      }
      final all = whole + fraction;
      value =
          scientific[1]! +
          (offset <= 0
              ? '0.${'0' * (-offset)}$all'
              : offset >= all.length
              ? '$all${'0' * (offset - all.length)}'
              : '${all.substring(0, offset)}.${all.substring(offset)}');
    }
    final match = RegExp(r'^([+-]?)(\d{1,13})(?:\.(\d+))?$').firstMatch(value);
    if (match == null) {
      throw const ToolFailure('金额格式无效，请输入十进制数字。');
    }
    var fraction = match[3] ?? '';
    if (fraction.length > precision) {
      if (fraction.substring(precision).contains(RegExp('[1-9]'))) {
        throw const ToolFailure('金额的小数位超出币种精度，未四舍五入。');
      }
      fraction = fraction.substring(0, precision);
    }
    final minor =
        int.parse(match[2]!) * _pow10(precision) +
        (fraction.isEmpty ? 0 : int.parse(fraction.padRight(precision, '0')));
    if (minor > 900000000000000) {
      throw const ToolFailure('金额超过本地安全范围。');
    }
    if (match[1] == '-' && minor != 0 && !signed) {
      throw const ToolFailure('金额不能为负，请单独选择交易方向。');
    }
    return match[1] == '-' ? -minor : minor;
  }

  static int _pow10(int digits) => digits == 0
      ? 1
      : digits == 3
      ? 1000
      : 100;
  static String format(int minor, {String currency = 'CNY'}) {
    final precision = digits(currency),
        factor = _pow10(precision),
        absolute = minor.abs();
    return '${minor < 0 ? '-' : ''}${absolute ~/ factor}${precision == 0 ? '' : '.${(absolute % factor).toString().padLeft(precision, '0')}'}';
  }
}
