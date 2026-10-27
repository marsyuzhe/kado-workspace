import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'api_studio_service.dart';
import 'dev_tool_widgets.dart';

final apiStudioProvider = Provider(
  (ref) => ApiStudioService(
    ref.watch(recordStoreProvider),
    ref.watch(credentialsProvider),
  ),
);

class ApiStudioPage extends ConsumerStatefulWidget {
  const ApiStudioPage({super.key});
  @override
  ConsumerState<ApiStudioPage> createState() => _ApiStudioPageState();
}

class _ApiStudioPageState extends ConsumerState<ApiStudioPage> {
  final url = TextEditingController(),
      headers = TextEditingController(text: '{}'),
      query = TextEditingController(text: '{}'),
      body = TextEditingController(),
      timeout = TextEditingController(text: '15');
  String method = 'GET', bodyType = 'text', collection = '', environment = '';
  ToolRecord? selected;
  ApiResult? response;
  CancelToken? token;
  Map<String, String> stringMap(String text) =>
      Map<String, String>.from(jsonDecode(text) as Map);
  ApiRequestSpec spec() => ApiRequestSpec.fromJson({
    'url': url.text,
    'method': method,
    'headers': stringMap(headers.text),
    'query': stringMap(query.text),
    'body': body.text,
    'bodyType': bodyType,
    'timeoutSeconds': int.tryParse(timeout.text) ?? 0,
  });
  @override
  void dispose() {
    token?.cancel();
    for (final c in [url, headers, query, body, timeout]) {
      c.dispose();
    }
    super.dispose();
  }

  void load(ToolRecord row) {
    final request = ApiRequestSpec.fromJson(row.data);
    setState(() {
      selected = row;
      url.text = request.url;
      method = request.method;
      headers.text = const JsonEncoder.withIndent('  ')
          .convert(request.headers);
      query.text = const JsonEncoder.withIndent('  ').convert(request.query);
      body.text = request.body;
      bodyType = request.bodyType;
      timeout.text = '${request.timeoutSeconds}';
      collection = row.text('collection');
      response = null;
    });
  }

  Future<void> send() async {
    final request = spec(), cancel = CancelToken();
    setState(() {
      token = cancel;
      response = null;
    });
    try {
      final env = environment.isEmpty
          ? null
          : await ref.read(recordStoreProvider).get(environment);
      final result = await ref
          .read(apiStudioProvider)
          .send(
            request,
            cancelToken: cancel,
            variables: env == null
                ? {}
                : Map<String, String>.from(env.data['variables'] as Map),
          );
      if (mounted) setState(() => response = result);
    } finally {
      if (mounted) setState(() => token = null);
    }
  }

  Future<void> save() async {
    final values = await ltEditForm(
      context,
      title: '保存请求',
      fields: [
        LTField('name', '名称', initial: selected?.title ?? '', required: true),
      ],
    );
    if (values == null) return;
    final row = await ref
        .read(apiStudioProvider)
        .save(
          values['name']!,
          spec(),
          existing: selected,
          collection: collection,
          favorite: selected?.flag('favorite') ?? false,
        );
    if (mounted) load(row);
  }

  Future<void> addEnvironment() async {
    final fields = await ltEditForm(
      context,
      title: '新建环境',
      fields: [
        const LTField('name', '环境名称', required: true),
        const LTField('base', 'Base URL', required: true),
        const LTField('variables', '普通变量JSON', initial: '{}', multiline: true),
        const LTField('secretName', '敏感变量名称（可选）'),
        const LTField('secretValue', '敏感值（仅写安全存储）', secret: true),
      ],
    );
    if (fields == null) return;
    final values = stringMap(fields['variables']!),
        secretName = fields['secretName']!.trim();
    if (values.length > 100 || fields['variables']!.length > 65536) {
      throw const ToolFailure('变量超过限制。');
    }
    values['baseUrl'] = fields['base']!;
    // Protect recognized sensitive variable names too, even when entered in the
    // ordinary JSON field. No plaintext credential is saved to app_settings.
    for (final e in {...values}.entries) {
      if (sensitiveApiKey.hasMatch(e.key)) {
        final id = newId();
        await ref.read(credentialsProvider).write('dev.api.$id', e.value);
        values[e.key] = '{{secret:$id}}';
      }
    }
    if (secretName.isNotEmpty) {
      if (!RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(secretName)) {
        throw const ToolFailure('敏感变量名称无效。');
      }
      final id = newId();
      await ref
          .read(credentialsProvider)
          .write('dev.api.$id', fields['secretValue']!);
      values[secretName] = '{{secret:$id}}';
    }
    final row = await ref
        .read(recordStoreProvider)
        .create(
          'api_environment',
          fields['name']!,
          data: {
            'variables': values,
            'syncAllowed': false,
            'isSensitive': true,
          },
        );
    if (mounted) setState(() => environment = row.id);
  }

  Future<void> export() async {
    final safe = await ref.read(apiStudioProvider).protect(spec());
    await saveDevText(
      'api-request.json',
      const JsonEncoder.withIndent('  ').convert({
        'format': 'kado-api-request',
        'version': 1,
        'name': selected?.title ?? 'Request',
        'request': safe.toJson(),
      }),
    );
  }

  Future<void> import() async {
    final text = await pickDevText();
    if (text == null) return;
    final raw = jsonDecode(text) as Map<String, dynamic>;
    if (raw['format'] != 'kado-api-request' || raw['version'] != 1) {
      throw const ToolFailure('不支持的请求文件。');
    }
    final request = ApiRequestSpec.fromJson(
      Map<String, dynamic>.from(raw['request'] as Map),
    );
    if (!mounted ||
        !await ltConfirm(
          context,
          title: '导入请求配置？',
          message:
              '${raw['name']} · ${request.method}\n导入只保存配置，不发起请求。安全变量需要在本机重新设置。',
        )) {
      return;
    }
    final row = await ref
        .read(apiStudioProvider)
        .save('${raw['name']}', request, collection: collection);
    if (mounted) load(row);
  }

  @override
  Widget build(BuildContext context) {
    final saved =
            ref.watch(recordsProvider('api_request')).asData?.value ??
            <ToolRecord>[],
        collections =
            ref.watch(recordsProvider('api_collection')).asData?.value ??
            <ToolRecord>[],
        environments =
            ref.watch(recordsProvider('api_environment')).asData?.value ??
            <ToolRecord>[];
    Object? json;
    bool isJson = false;
    if (response != null) {
      try {
        json = jsonDecode(response!.body);
        isJson = true;
      } on FormatException {
        /* Raw body remains available. */
      }
    }
    return PageFrame(
      eyebrow: 'DEVELOPER TOOLS',
      title: 'API Studio',
      description: '主动请求HTTP(S)，支持本机和局域网。无自动跳转或重试。{{baseUrl}} / {{变量名}}；敏感值通过安全变量引用，普通Text Body请勿保存密钥。',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DropdownMenu<String>(
              label: const Text('方法'),
              initialSelection: method,
              key: ValueKey(method),
              dropdownMenuEntries: [
                for (final m in apiMethods)
                  DropdownMenuEntry(value: m, label: m),
              ],
              onSelected: token != null
                  ? null
                  : (v) => setState(() => method = v!),
            ),
            SizedBox(
              width: 120,
              child: LTTextField(controller: timeout, label: '超时（秒）'),
            ),
            LTButton(
              label: '发送',
              onPressed: token != null ? null : () => runUi(context, send),
            ),
            if (token != null)
              TextButton(
                onPressed: () => token!.cancel(),
                child: const Text('取消'),
              ),
            TextButton(
              onPressed: () => runUi(context, save),
              child: const Text('保存请求'),
            ),
            TextButton(
              onPressed: () => runUi(context, import),
              child: const Text('导入配置'),
            ),
            TextButton(
              onPressed: () => runUi(context, export),
              child: const Text('导出配置'),
            ),
          ],
        ),
        DevTextEditor(controller: url, label: '请求URL', lines: 2),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            DropdownMenu<String>(
              label: const Text('集合 / 项目'),
              initialSelection: collection,
              key: ValueKey('collection-$collection-${collections.length}'),
              dropdownMenuEntries: [
                const DropdownMenuEntry(value: '', label: '未分类'),
                for (final c in collections)
                  DropdownMenuEntry(value: c.id, label: c.title),
              ],
              onSelected: (v) => setState(() => collection = v ?? ''),
            ),
            TextButton(
              onPressed: () => runUi(context, () async {
                final fields = await ltEditForm(
                  context,
                  title: '新建集合',
                  fields: [const LTField('name', '名称', required: true)],
                );
                if (fields != null) {
                  final row = await ref
                      .read(recordStoreProvider)
                      .create('api_collection', fields['name']!);
                  if (mounted) setState(() => collection = row.id);
                }
              }),
              child: const Text('新建集合'),
            ),
            DropdownMenu<String>(
              label: const Text('环境'),
              initialSelection: environment,
              key: ValueKey('env-$environment-${environments.length}'),
              dropdownMenuEntries: [
                const DropdownMenuEntry(value: '', label: '无环境'),
                for (final e in environments)
                  DropdownMenuEntry(value: e.id, label: e.title),
              ],
              onSelected: (v) => setState(() => environment = v ?? ''),
            ),
            TextButton(
              onPressed: () => runUi(context, addEnvironment),
              child: const Text('新建环境'),
            ),
          ],
        ),
        DevTextEditor(controller: query, label: 'Query（字符串对象JSON）', lines: 3),
        DevTextEditor(
          controller: headers,
          label: 'Headers（字符串对象JSON）',
          lines: 3,
        ),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: bodyType,
          key: ValueKey(bodyType),
          decoration: const InputDecoration(labelText: 'Body类型'),
          items: const [
            DropdownMenuItem(value: 'text', child: Text('Text')),
            DropdownMenuItem(value: 'json', child: Text('JSON')),
            DropdownMenuItem(
              value: 'form',
              child: Text('Form URL Encoded（字符串对象JSON）'),
            ),
          ],
          onChanged: (v) => setState(() => bodyType = v!),
        ),
        DevTextEditor(controller: body, label: 'Body'),
        if (token != null) const LinearProgressIndicator(),
        if (response != null) ...[
          LTSectionHeader(
            'Status ${response!.status} · ${response!.elapsedMs}ms · ${response!.size} bytes',
          ),
          Text(response!.contentType),
          TextButton(
            onPressed: () => copyDevText(response!.body),
            child: const Text('复制响应'),
          ),
          ExpansionTile(
            title: const Text('响应Headers'),
            children: [
              DevOutput(
                text: const JsonEncoder.withIndent('  ')
                    .convert(response!.headers),
              ),
            ],
          ),
          DevOutput(text: response!.body),
          if (isJson) JsonTree(value: json),
        ],
        const SizedBox(height: 16),
        const LTSectionHeader('已保存请求'),
        for (final row in saved.where(
          (r) => collection.isEmpty || r.text('collection') == collection,
        ))
          ListTile(
            title: Text(row.title),
            subtitle: Text(
              '${row.text('method')} ${row.text('url')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => load(row),
            trailing: IconButton(
              tooltip: '收藏请求',
              icon: Icon(row.flag('favorite') ? Icons.star : Icons.star_border),
              onPressed: () => runUi(
                context,
                () => ref
                    .read(recordStoreProvider)
                    .save(
                      row.copyWith(
                        data: {...row.data, 'favorite': !row.flag('favorite')},
                      ),
                    ),
              ),
            ),
          ),
      ],
    );
  }
}
