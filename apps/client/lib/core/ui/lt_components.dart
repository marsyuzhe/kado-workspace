import 'package:flutter/material.dart';

import 'app_theme.dart';

enum LTButtonStyle { primary, secondary, ghost, danger }

class LTButton extends StatelessWidget {
  const LTButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.style = LTButtonStyle.primary,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final LTButtonStyle style;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<DesignTokens>()!;
    final leading = loading
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : icon == null
        ? null
        : Icon(icon, size: 18);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 8)],
        Flexible(child: Text(label)),
      ],
    );
    final action = loading ? null : onPressed;
    return Semantics(
      button: true,
      label: loading ? '$label，处理中' : null,
      child: switch (style) {
        LTButtonStyle.primary => FilledButton(
          onPressed: action,
          child: content,
        ),
        LTButtonStyle.secondary => OutlinedButton(
          onPressed: action,
          child: content,
        ),
        LTButtonStyle.ghost => TextButton(onPressed: action, child: content),
        LTButtonStyle.danger => FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: t.danger,
            foregroundColor: t.background,
          ),
          onPressed: action,
          child: content,
        ),
      },
    );
  }
}

class LTIconButton extends StatelessWidget {
  const LTIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 20),
  );
}

class LTTextField extends StatelessWidget {
  const LTTextField({
    super.key,
    this.controller,
    required this.label,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.maxLines = 1,
    this.obscure = false,
    this.autofocus = false,
    this.enabled = true,
    this.error,
    this.keyboardType,
  });
  final TextEditingController? controller;
  final String label;
  final String? hint, error;
  final ValueChanged<String>? onChanged, onSubmitted;
  final int maxLines;
  final bool obscure, autofocus, enabled;
  final TextInputType? keyboardType;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
    ),
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    maxLines: obscure ? 1 : maxLines,
    obscureText: obscure,
    autofocus: autofocus,
    enabled: enabled,
    keyboardType: keyboardType,
  );
}

class LTSearchField extends StatelessWidget {
  const LTSearchField({
    super.key,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.hint = '搜索',
    this.autofocus = false,
  });
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged, onSubmitted;
  final String hint;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    autofocus: autofocus,
    decoration: InputDecoration(
      hintText: hint,
      prefixIcon: const Icon(Icons.search_rounded, size: 20),
      suffixIcon: controller == null
          ? null
          : ValueListenableBuilder(
              valueListenable: controller!,
              builder: (context, value, child) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : LTIconButton(
                      icon: Icons.close,
                      tooltip: '清除搜索',
                      onPressed: () {
                        controller!.clear();
                        onChanged?.call('');
                      },
                    ),
            ),
    ),
  );
}

class LTCard extends StatelessWidget {
  const LTCard({super.key, required this.child, this.padding, this.onTap});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: onTap == null
        ? Padding(
            padding: padding ?? EdgeInsets.all(AppDensity.inset(context)),
            child: child,
          )
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.large),
            child: Padding(
              padding: padding ?? EdgeInsets.all(AppDensity.inset(context)),
              child: child,
            ),
          ),
  );
}

class LTBadge extends StatelessWidget {
  const LTBadge(this.label, {super.key, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<DesignTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: (color ?? t.accent).withValues(alpha: .09),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(color: color ?? t.textSecondary, fontSize: 11),
      ),
    );
  }
}

class LTEmptyState extends StatelessWidget {
  const LTEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });
  final String title, message;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<DesignTokens>()!;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: t.textSecondary),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(color: t.textSecondary, height: 1.6),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class LTLoadingState extends StatelessWidget {
  const LTLoadingState({super.key, this.label = '正在加载'});
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label),
          ],
        ),
      ),
    ),
  );
}

class LTErrorState extends StatelessWidget {
  const LTErrorState({
    super.key,
    this.message = '操作未能完成。请检查权限或连接后重试。',
    this.onRetry,
  });
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => LTEmptyState(
    title: '暂时无法完成',
    message: message,
    icon: Icons.error_outline,
    action: onRetry == null ? null : LTButton(label: '重试', onPressed: onRetry),
  );
}

class LTSectionHeader extends StatelessWidget {
  const LTSectionHeader(this.title, {super.key, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ?action,
      ],
    ),
  );
}

class LTToolbar extends StatelessWidget {
  const LTToolbar({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );
}

class LTDataTable extends StatelessWidget {
  const LTDataTable({super.key, required this.columns, required this.rows});
  final List<DataColumn> columns;
  final List<DataRow> rows;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(columns: columns, rows: rows),
  );
}

void ltMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));

Future<bool> ltConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool dangerous = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          LTButton(
            label: confirmLabel,
            style: dangerous ? LTButtonStyle.danger : LTButtonStyle.primary,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    ) ??
    false;

class LTField {
  const LTField(
    this.id,
    this.label, {
    this.initial = '',
    this.multiline = false,
    this.secret = false,
    this.required = false,
    this.hint,
    this.options,
  });
  final String id, label, initial;
  final bool multiline, secret, required;
  final String? hint;
  final Map<String, String>? options;
}

Future<Map<String, String>?> ltEditForm(
  BuildContext context, {
  required String title,
  required List<LTField> fields,
  String? description,
  String submit = '保存',
}) => showDialog<Map<String, String>>(
  context: context,
  builder: (context) => _LTEditorDialog(
    title: title,
    fields: fields,
    description: description,
    submit: submit,
  ),
);

class _LTEditorDialog extends StatefulWidget {
  const _LTEditorDialog({
    required this.title,
    required this.fields,
    required this.submit,
    this.description,
  });
  final String title, submit;
  final String? description;
  final List<LTField> fields;
  @override
  State<_LTEditorDialog> createState() => _LTEditorDialogState();
}

class _LTEditorDialogState extends State<_LTEditorDialog> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> controllers;
  @override
  void initState() {
    super.initState();
    controllers = {
      for (final field in widget.fields)
        field.id: TextEditingController(text: field.initial),
    };
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: SizedBox(
      width: 500,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.description != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(widget.description!),
              ),
            for (final field in widget.fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: field.options != null
                    ? DropdownButtonFormField<String>(
                        initialValue: field.options!.containsKey(field.initial)
                            ? field.initial
                            : null,
                        isExpanded: true,
                        decoration: InputDecoration(labelText: field.label),
                        items: [
                          for (final entry in field.options!.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(
                                entry.value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) =>
                            controllers[field.id]!.text = value ?? '',
                        validator: (value) =>
                            field.required && (value?.isEmpty ?? true)
                            ? '请填写${field.label}'
                            : null,
                      )
                    : TextFormField(
                        controller: controllers[field.id],
                        obscureText: field.secret,
                        minLines: field.multiline ? 3 : 1,
                        maxLines: field.multiline ? 8 : 1,
                        decoration: InputDecoration(
                          labelText: field.label,
                          hintText: field.hint,
                        ),
                        validator: (value) =>
                            field.required && (value?.trim().isEmpty ?? true)
                            ? '请填写${field.label}'
                            : null,
                      ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      LTButton(
        label: widget.submit,
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, {
              for (final item in controllers.entries) item.key: item.value.text,
            });
          }
        },
      ),
    ],
  );
}
