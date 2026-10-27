import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Lazy records stay in a sliver list; headers scroll away on short windows.
class LTScrollPage extends StatelessWidget {
  const LTScrollPage({
    super.key,
    required this.title,
    required this.description,
    this.header = const [],
    required this.itemCount,
    required this.itemBuilder,
    this.empty,
  });
  final String title, description;
  final List<Widget> header;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Widget? empty;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final padding = c.maxWidth < 600 ? 20.0 : 32.0;
      final t = Theme.of(context).extension<DesignTokens>()!;
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.all(padding),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    description,
                    style: TextStyle(color: t.textSecondary, height: 1.7),
                  ),
                  const SizedBox(height: 24),
                  ...header,
                ],
              ),
            ),
          ),
          if (itemCount == 0)
            SliverToBoxAdapter(child: empty ?? const SizedBox.shrink())
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padding, 0, padding, 32),
              sliver: SliverList.builder(
                itemCount: itemCount,
                itemBuilder: itemBuilder,
              ),
            ),
        ],
      );
    },
  );
}
