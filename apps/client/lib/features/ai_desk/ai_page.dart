import '../dev_tools/snippet_page.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/local_markdown.dart';
import '../../shared/record_ui.dart';
import 'ai_service.dart';

class AiDeskPage extends ConsumerStatefulWidget {
  const AiDeskPage({super.key, this.conversationId, this.initialProviderId});
  final String? conversationId;
  final String? initialProviderId;
  @override
  ConsumerState<AiDeskPage> createState() => _AiDeskPageState();
}

class _AiDeskPageState extends ConsumerState<AiDeskPage> {
  final input = TextEditingController();
  AiChatRunner? runner;
  String live = '', modelList = '';
  String? error;
  bool generating = false, configBusy = false;
  String? selectedProvider;
  AiRepository get repo => ref.read(aiRepositoryProvider);
  @override
  void initState() {
    super.initState();
    selectedProvider = widget.initialProviderId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(
          () => input.text = ref.read(aiDraftProvider.notifier).consume(),
        );
      }
    });
  }

  @override
  void dispose() {
    final current = runner;
    if (current != null) unawaited(current.stop());
    input.dispose();
    super.dispose();
  }

  Future<void> editProvider([ToolRecord? existing]) async {
    final config = existing == null ? null : AiConfig.fromRecord(existing);
    final values = await ltEditForm(
      context,
      title: existing == null ? '添加AI服务' : '编辑AI服务',
      description: '使用OpenAI或兼容Chat Completions的/v1接口。API Key保存在系统安全存储；留空保留原Key。单价按每百万Token填写，留空则不估算费用。',
      fields: [
        LTField(
          'name',
          'Provider名称',
          initial: config?.name ?? '',
          required: true,
        ),
        LTField(
          'base',
          'Base URL',
          initial: config?.baseUrl ?? 'https://api.openai.com/v1',
          required: true,
        ),
        LTField('key', 'API Key（留空保留）', secret: true),
        LTField(
          'model',
          '默认模型ID（自行填写或读取服务模型列表）',
          initial: config?.model ?? '',
          required: true,
        ),
        LTField('timeout', '超时秒数', initial: '${config?.timeout ?? 60}'),
        LTField('max', '最大输出Token', initial: '${config?.maxTokens ?? 2048}'),
        LTField(
          'temperature',
          'temperature（模型不支持时留空）',
          initial: config?.temperature?.toString() ?? '',
        ),
        LTField(
          'usage',
          '请求Usage：1开启 / 0兼容模式',
          initial: config?.includeUsage == false ? '0' : '1',
        ),
        LTField('currency', '币种', initial: config?.currency ?? 'USD'),
        LTField(
          'input',
          '输入单价 / 1M Token',
          initial: config?.inputPrice?.toString() ?? '',
        ),
        LTField(
          'output',
          '输出单价 / 1M Token',
          initial: config?.outputPrice?.toString() ?? '',
        ),
      ],
    );
    if (values == null || !mounted) return;
    await runUi(context, () async {
      double? number(String id) {
        if (values[id]!.trim().isEmpty) return null;
        final v = double.tryParse(values[id]!);
        if (v == null) throw const ToolFailure('数字格式无效。');
        return v;
      }

      final base = values['base']!.trim();
      final value = AiConfig(
        name: values['name']!,
        baseUrl: base,
        model: values['model']!.trim(),
        official:
            base.replaceAll(RegExp(r'/+$'), '') == 'https://api.openai.com/v1',
        timeout: int.tryParse(values['timeout']!) ?? 0,
        maxTokens: int.tryParse(values['max']!) ?? 0,
        temperature: number('temperature'),
        includeUsage: values['usage'] == '1',
        currency: values['currency']!.trim().toUpperCase(),
        inputPrice: number('input'),
        outputPrice: number('output'),
      );
      final provider = await repo.configure(
        value,
        key: values['key'],
        existing: existing,
      );
      if (mounted) setState(() => selectedProvider = provider.id);
    });
  }

  Future<void> models(ToolRecord provider) async {
    setState(() => configBusy = true);
    final result = await runUi(
      context,
      () async => ref
          .read(aiApiProvider)
          .models(AiConfig.fromRecord(provider), await repo.key(provider)),
    );
    if (mounted) {
      setState(() {
        configBusy = false;
        modelList = result == null
            ? '模型列表未读取成功。若服务不支持/models，可手动填写ID。'
            : '${result.length}个服务端模型：\n${result.join('\n')}';
      });
    }
  }

  Future<void> newChat(ToolRecord provider) async {
    final chat = await runUi(context, () => repo.newConversation(provider));
    if (chat != null && mounted) {
      ref.read(aiDraftProvider.notifier).setDraft(input.text);
      context.go(
        Uri(
          path: '/modules/ai_desk',
          queryParameters: {'id': chat.id},
        ).toString(),
      );
    }
  }

  Future<void> send(
    ToolRecord conversation,
    ToolRecord provider, {
    bool retry = false,
  }) async {
    if (generating) return;
    final text = input.text;
    if (!retry && text.trim().isEmpty) return;
    if (!retry) input.clear();
    final watch = Stopwatch()..start();
    var lastFrame = -100;
    final current = AiChatRunner(
      repo,
      ref.read(aiApiProvider),
      onUpdate: (text, busy, message) {
        if (!mounted) return;
        if (!busy || watch.elapsedMilliseconds - lastFrame >= 40) {
          lastFrame = watch.elapsedMilliseconds;
          setState(() {
            live = text;
            generating = busy;
            error = message;
          });
        }
      },
    );
    runner = current;
    setState(() {
      generating = true;
      live = '';
      error = null;
    });
    await current.send(conversation, provider, text, retry: retry);
  }

  Future<void> choosePrompt() async {
    final clipboard = await ref.read(recordStoreProvider).list('prompt');
    final memory = await ref.read(recordStoreProvider).list('memory_prompt');
    if (!mounted) return;
    final chosen = await showDialog<ToolRecord>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择要插入的提示词'),
        children: [
          if (clipboard.isEmpty && memory.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('先在剪贴板或记忆仓库保存提示词。'),
            ),
          for (final r in [...clipboard, ...memory])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, r),
              child: Text('${r.title}${r.flag('isSensitive') ? ' · 私密' : ''}'),
            ),
        ],
      ),
    );
    if (chosen != null && mounted) {
      input.text =
          '${input.text}${input.text.isEmpty ? '' : '\n'}${chosen.body}';
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = ref.watch(recordsProvider('ai_provider')).value ?? [];
    final conversations =
        ref.watch(recordsProvider('ai_conversation')).value ?? [];
    final conversation = conversations
        .where((c) => c.id == widget.conversationId)
        .firstOrNull;
    final provider =
        providers
            .where(
              (p) =>
                  p.id ==
                  (conversation?.text('providerId') ?? selectedProvider),
            )
            .firstOrNull ??
        (conversation == null ? providers.firstOrNull : null);
    final messages =
        ref.watch(aiMessagesProvider(conversation?.id ?? '')).value ?? [];
    return LTScrollPage(
      title: 'AI 控制台',
      description: '连接你配置的API服务。聊天内容和历史保存在本机，只有点击发送才提交选中的对话内容。',
      header: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LTButton(
              label: '添加AI服务',
              onPressed: generating ? null : () => editProvider(),
              icon: Icons.add,
            ),
            if (provider != null) ...[
              LTButton(
                label: '编辑服务',
                onPressed: generating ? null : () => editProvider(provider),
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '测试连接 / 获取模型',
                loading: configBusy,
                onPressed: generating || configBusy
                    ? null
                    : () => models(provider),
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '新建对话',
                onPressed: generating ? null : () => newChat(provider),
                style: LTButtonStyle.secondary,
              ),
              LTButton(
                label: '删除服务',
                onPressed: generating
                    ? null
                    : () async {
                        if (await ltConfirm(
                              context,
                              title: '删除服务配置？',
                              message: '删除此Provider和本机安全存储中的Key；既有历史仍保留。',
                              confirmLabel: '删除',
                            ) &&
                            context.mounted) {
                          await runUi(
                            context,
                            () => repo.removeProvider(provider),
                          );
                        }
                      },
                style: LTButtonStyle.danger,
              ),
            ],
          ],
        ),
        if (providers.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in providers)
                ChoiceChip(
                  label: Text('${p.title} · ${p.text('model')}'),
                  selected: p.id == provider?.id,
                  onSelected: generating || conversation != null
                      ? null
                      : (_) => setState(() => selectedProvider = p.id),
                ),
            ],
          ),
        if (providers.isEmpty)
          const LTEmptyState(
            title: '配置你的API服务',
            message: '填写服务地址、API Key和真实模型ID后，可测试连接并创建对话。ChatGPT订阅不会自动提供API配额。',
            icon: Icons.key_outlined,
          ),
        if (conversation == null && input.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: TextField(
              controller: input,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: '待发送草稿（新建对话后可发送）'),
            ),
          ),
        if (modelList.isNotEmpty)
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('模型列表 / 连接结果'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(modelList),
              ),
            ],
          ),
        if (conversations.isNotEmpty)
          ExpansionTile(
            title: const Text('历史对话'),
            children: [
              for (final c in conversations.take(50))
                ListTile(
                  title: Text(c.title),
                  subtitle: Text(
                    '${readableTime(c.updatedAt)} · ${c.text('model')}',
                  ),
                  onTap: generating
                      ? null
                      : () => context.go(
                          Uri(
                            path: '/modules/ai_desk',
                            queryParameters: {'id': c.id},
                          ).toString(),
                        ),
                  trailing: IconButton(
                    tooltip: '删除对话',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: generating
                        ? null
                        : () async {
                            if (await ltConfirm(
                                  context,
                                  title: '删除此对话？',
                                  message: '本机历史消息将删除。',
                                  confirmLabel: '删除',
                                ) &&
                                context.mounted) {
                              await runUi(context, () async {
                                await repo.clearConversation(c, remove: true);
                                if (context.mounted &&
                                    conversation?.id == c.id) {
                                  context.go('/modules/ai_desk');
                                }
                              });
                            }
                          },
                  ),
                ),
            ],
          ),
        if (conversation != null) ...[
          Text('当前对话 · ${conversation.title}'),
          Wrap(
            spacing: 8,
            children: [
              LTButton(
                label: '重命名',
                onPressed: generating
                    ? null
                    : () async {
                        final value = await ltEditForm(
                          context,
                          title: '重命名对话',
                          fields: [
                            LTField(
                              'title',
                              '标题',
                              initial: conversation.title,
                              required: true,
                            ),
                          ],
                        );
                        if (value != null && context.mounted) {
                          await runUi(
                            context,
                            () => repo.store.save(
                              conversation.copyWith(title: value['title']),
                            ),
                          );
                        }
                      },
                style: LTButtonStyle.ghost,
              ),
              LTButton(
                label: '切换模型',
                onPressed: generating || provider == null
                    ? null
                    : () async {
                        final value = await ltEditForm(
                          context,
                          title: '此对话使用的模型',
                          description: '手动填写服务端真实模型ID。仅影响后续请求。',
                          fields: [
                            LTField(
                              'model',
                              '模型ID',
                              initial: conversation.text('model'),
                              required: true,
                            ),
                          ],
                        );
                        if (value != null && context.mounted) {
                          await runUi(
                            context,
                            () => repo.store.save(
                              conversation.copyWith(
                                data: {
                                  ...conversation.data,
                                  'model': value['model']!.trim(),
                                },
                              ),
                            ),
                          );
                        }
                      },
                style: LTButtonStyle.ghost,
              ),
              LTButton(
                label: '清空对话',
                onPressed: generating
                    ? null
                    : () async {
                        if (await ltConfirm(
                              context,
                              title: '清空对话？',
                              message: '删除本机消息，不能撤销。',
                              confirmLabel: '清空',
                            ) &&
                            context.mounted) {
                          await runUi(
                            context,
                            () => repo.clearConversation(conversation),
                          );
                        }
                      },
                style: LTButtonStyle.ghost,
              ),
            ],
          ),
          if (provider == null) const Text('原服务配置已移除。历史可查看；请新建配置和对话继续使用。'),
          const SizedBox(height: 12),
          TextField(
            controller: input,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: '输入内容（发送前可编辑）'),
            enabled: !generating,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              LTButton(
                label: '发送',
                onPressed: generating || provider == null
                    ? null
                    : () => send(
                        conversation,
                        provider.copyWith(
                          data: {
                            ...provider.data,
                            'model': conversation.text(
                              'model',
                              provider.text('model'),
                            ),
                          },
                        ),
                      ),
                icon: Icons.send_outlined,
              ),
              LTButton(
                label: '选择提示词',
                onPressed: generating ? null : choosePrompt,
                style: LTButtonStyle.secondary,
              ),
              if (generating)
                LTButton(
                  label: '停止生成',
                  onPressed: () => runner?.stop(),
                  style: LTButtonStyle.danger,
                ),
              if (!generating &&
                  messages.lastOrNull?.text('role') == 'assistant' &&
                  {
                    'failed',
                    'cancelled',
                  }.contains(messages.lastOrNull?.text('status')))
                LTButton(
                  label: '重试最后一轮',
                  onPressed: provider == null
                      ? null
                      : () => send(
                          conversation,
                          provider.copyWith(
                            data: {
                              ...provider.data,
                              'model': conversation.text(
                                'model',
                                provider.text('model'),
                              ),
                            },
                          ),
                          retry: true,
                        ),
                  style: LTButtonStyle.secondary,
                ),
            ],
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(error!),
          ),
        if (generating || live.isNotEmpty && error != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(generating ? '正在生成…' : '本次回复（可复制）'),
                  LocalMarkdown(text: live),
                  TextButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: live)),
                    child: const Text('复制当前回答'),
                  ),
                ],
              ),
            ),
          ),
      ],
      itemCount: messages.length,
      itemBuilder: (_, i) {
        final message = messages[i];
        final usage = message.data['usage'] as Map?;
        final code = RegExp(r'```[^\n]*\n([\s\S]*?)```')
            .allMatches(message.body)
            .map((m) => m.group(1)!)
            .toList();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${message.text('role') == 'user' ? '你' : '助手'} · ${message.text('status')}',
                ),
                const SizedBox(height: 8),
                LocalMarkdown(text: message.body),
                if (message.text('error').isNotEmpty)
                  Text(message.text('error')),
                if (usage != null)
                  Text(
                    '${message.text('usageSource') == 'server' ? '服务端Usage' : '估算Usage（按字符粗算）'}：输入${usage['prompt_tokens'] ?? '不可用'} / 输出${usage['completion_tokens'] ?? '不可用'} Token${message.data['cost'] == null ? ' · 未设置价格，费用不可用' : ' · ${message.text('currency')} ${(message.data['cost'] as num).toStringAsFixed(6)}（按输入/输出每百万Token单价计算）'}',
                  ),
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: message.body)),
                  child: const Text('复制内容'),
                ),
                TextButton(
                  onPressed: () => runUi(
                    context,
                    () => saveSnippetDialog(
                      context,
                      ref,
                      code: code.isNotEmpty ? code.first : message.body,
                      sourceId: message.id,
                    ),
                  ),
                  child: const Text('保存代码片段'),
                ),
                for (var i = 0; i < code.length; i++)
                  TextButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: code[i])),
                    child: Text('复制代码块 ${i + 1}'),
                  ),
              ],
            ),
          ),
        );
      },
      empty: conversation == null
          ? const LTEmptyState(
              title: '选择服务后新建对话',
              message: '不会生成示例回答；联网验收需要你自己的有效API配置。',
              icon: Icons.chat_bubble_outline,
            )
          : const SizedBox(),
    );
  }
}
