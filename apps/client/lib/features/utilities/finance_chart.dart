import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'finance_service.dart';
import 'money.dart';

class FinanceTrendChart extends StatelessWidget {
  const FinanceTrendChart({
    super.key,
    required this.report,
    required this.year,
    required this.currency,
  });
  final FinanceReport report;
  final int year;
  final String currency;
  @override
  Widget build(BuildContext context) {
    final months = List.generate(
      12,
      (i) => '$year-${(i + 1).toString().padLeft(2, '0')}',
    );
    final income = [for (final key in months) report.trends[key]?.income ?? 0],
        expense = [
          for (final key in months)
            (report.trends[key]?.expense ?? 0) -
                (report.trends[key]?.refunds ?? 0),
        ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$year 月度收支趋势 · $currency'),
        const Text('蓝线：收入　橙线：扣除退款后的净支出；内部转账和撤销不计入。'),
        SizedBox(
          height: 180,
          child: CustomPaint(
            painter: _TrendPainter(
              income,
              expense,
              Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            for (var i = 0; i < 12; i++)
              Text(
                '${i + 1}月 ${Money.format(income[i], currency: currency)} / ${Money.format(expense[i], currency: currency)}',
              ),
          ],
        ),
      ],
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.income, this.expense, this.foreground);
  final List<int> income, expense;
  final Color foreground;
  @override
  void paint(Canvas canvas, Size size) {
    final all = [0, ...income, ...expense],
        low = all.reduce(math.min).toDouble(),
        high = all.reduce(math.max).toDouble(),
        range = math.max(1, high - low);
    final area = Rect.fromLTRB(
      20,
      14,
      math.max(21, size.width - 12),
      size.height - 25,
    );
    double y(int value) => area.bottom - (value - low) / range * area.height;
    final axis = Paint()
      ..color = foreground.withValues(alpha: .2)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(area.left, y(0)), Offset(area.right, y(0)), axis);
    void line(List<int> values, Color color) {
      final path = Path();
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < 12; i++) {
        final point = Offset(area.left + i * area.width / 11, y(values[i]));
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
        canvas.drawCircle(point, 2, Paint()..color = color);
      }
      canvas.drawPath(path, paint);
    }

    line(income, const Color(0xff80a7ef));
    line(expense, const Color(0xffe5aa71));
    for (var i = 0; i < 12; i++) {
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(color: foreground, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(
          area.left + i * area.width / 11 - label.width / 2,
          area.bottom + 8,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.income != income ||
      old.expense != expense ||
      old.foreground != foreground;
}
