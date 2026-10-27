import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data_providers.dart';
import '../../core/data/tool_record.dart';
import '../../core/ui/lt_components.dart';
import '../../core/ui/lt_scroll_page.dart';
import '../../shared/record_ui.dart';
import 'server_service.dart';

class ServerPage extends ConsumerStatefulWidget {
  const ServerPage({super.key, this.serverId});
  final String? serverId;
  @override
  ConsumerState<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends ConsumerState<ServerPage> {
  ServerConnection? connection;
  ToolRecord? connectedServer;
  ServerSnapshot? snapshot;
  bool connecting = false, reading = false;
  int generation = 0;
  String? error;
  final checking = <String>{};
  ServerRepository get repo => ref.read(serverRepositoryProvider);
  @override
  void dispose() {
    generation++;
    final current = connection;
    if (current != null) unawaited(current.close());
    super.dispose();
  }

  Future<void> configure([ToolRecord? existing]) async {
    final config = existing == null ? null : ServerConfig.fromRecord(existing);
    final response = await ltEditForm(
      context,
      title: existing == null ? '添加Linux服务器' : '编辑服务器',
      description:
          '密码/私钥放在本机系统安全存储。认证填写password或key；key模式保存时通过文件选择器导入私钥。留空保留原凭据。',
      fields: [
        LTField('name', '名称', initial: config?.name ?? '', required: true),
        LTField('host', 'IP或主机名', initial: config?.host ?? '', required: true),
        LTField(
          'port',
          'SSH端口',
          initial: '${config?.port ?? 22}',
          required: true,
        ),
        LTField('user', '用户名', initial: config?.username ?? '', required: true),
        LTField(
          'auth',
          '认证方式：password / key',
          initial: config?.auth ?? 'password',
        ),
        const LTField('password', '密码（key模式留空）', secret: true),
        const LTField('passphrase', '私钥口令（如有）', secret: true),
        LTField('tags', '标签，逗号分隔', initial: config?.tags.join(',') ?? ''),
        LTField(
          'notes',
          '配置说明/备注',
          initial: config?.notes ?? '',
          multiline: true,
        ),
        LTField('timeout', '超时秒数', initial: '${config?.timeout ?? 20}'),
      ],
    );
    if (response == null || !mounted) return;
    await runUi(context, () async {
      final auth = response['auth']!.trim();
      String? secret = response['password'];
      if (auth == 'key') {
        final file = await FilePicker.pickFile(dialogTitle: '选择私钥（取消则保留原密钥）');
        if (file != null) {
          final bytes = <int>[];
          await for (final chunk in file.readAsByteStream()) {
            bytes.addAll(chunk);
            if (bytes.length > 128 * 1024) {
              throw const ToolFailure('私钥文件超过128KB，已拒绝。');
            }
          }
          secret = utf8.decode(bytes);
        }
      }
      await repo.save(
        ServerConfig(
          name: response['name']!,
          host: response['host']!,
          username: response['user']!,
          port: int.tryParse(response['port']!) ?? 0,
          auth: auth,
          tags: response['tags']!
              .split(RegExp('[,，]'))
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(),
          notes: response['notes']!,
          timeout: int.tryParse(response['timeout']!) ?? 0,
        ),
        secret: secret,
        passphrase: response['passphrase']!,
        existing: existing,
      );
    });
  }

  Future<void> connect(ToolRecord server) async {
    if (connecting) return;
    await disconnect();
    final request = ++generation;
    setState(() {
      connecting = true;
      error = null;
    });
    try {
      final credentials = await repo.secret(server);
      final client = await ref.read(serverConnectorProvider).connect(
        ServerConfig.fromRecord(server),
        credentials,
        (type, fingerprint) async {
          if (!mounted || request != generation) return false;
          return repo.verifyHost(server, type, fingerprint, (
            type,
            fingerprint,
          ) async {
            if (!mounted) return false;
            return ltConfirm(
              context,
              title: '首次连接：核对SSH主机指纹',
              message:
                  '目标：${server.text('host')}:${server.number('port', 22)}\n算法：$type\n指纹：$fingerprint\n\n请通过服务器控制台等可信渠道核对，确认后将固定此指纹。',
              confirmLabel: '核对一致并信任',
            );
          });
        },
      );
      if (!mounted || request != generation) {
        await client.close();
        return;
      }
      setState(() {
        connection = client;
        connectedServer = server;
        connecting = false;
      });
      await refresh();
    } catch (e) {
      if (mounted && request == generation) {
        setState(() {
          connecting = false;
          error = e is ToolFailure ? e.message : '连接失败，请核对配置。';
        });
      }
    }
  }

  Future<void> disconnect() async {
    generation++;
    final client = connection;
    connection = null;
    connectedServer = null;
    snapshot = null;
    if (mounted) setState(() => connecting = false);
    await client?.close();
  }

  Future<void> dockerRead(String command) async {
    final current = connection;
    if (current == null || reading) return;
    setState(() => reading = true);
    try {
      final result = await current.run(command);
      if (result.exitCode != 0) {
        throw const ToolFailure('Docker只读查询失败；检查容器、权限或Docker状态。');
      }
      if (!mounted || !identical(current, connection)) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Docker · 只读结果'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(child: SelectableText(result.output)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  Future<void> refresh() async {
    final current = connection;
    if (current == null || reading) return;
    setState(() => reading = true);
    try {
      final value = await ServerMonitor().read(current);
      if (mounted && identical(current, connection)) {
        setState(() => snapshot = value);
      }
    } catch (_) {
      if (mounted) setState(() => error = '监控读取失败，请检查SSH连接。');
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  Future<void> website([ToolRecord? existing]) async {
    final response = await ltEditForm(
      context,
      title: '网站监控',
      fields: [
        LTField('name', '名称', initial: existing?.title ?? '', required: true),
        LTField(
          'url',
          'HTTP/HTTPS网址',
          initial: existing?.text('url') ?? '',
          required: true,
        ),
      ],
    );
    if (response != null && mounted) {
      await runUi(
        context,
        () => repo.website(
          response['name']!,
          response['url']!,
          existing: existing,
        ),
      );
    }
  }

  Future<void> checkWebsite(ToolRecord website) async {
    setState(() => checking.add(website.id));
    await runUi(context, () async {
      final result = await WebsiteMonitor().check(website.text('url'));
      await ref
          .read(recordStoreProvider)
          .save(
            website.copyWith(
              data: {...website.data, 'lastCheck': result.toJson()},
            ),
          );
    });
    if (mounted) setState(() => checking.remove(website.id));
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(recordsProvider('server')).value ?? [];
    final websites = ref.watch(recordsProvider('website')).value ?? [];
    final current = connectedServer;
    return LTScrollPage(
      title: '服务器',
      description:
          '配置自己的Linux服务器，以固定主机指纹连接SSH。只读取监控信息与Docker状态；网站检查读取HTTP状态和TLS证书。',
      header: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LTButton(
              label: '添加服务器',
              onPressed: connecting ? null : () => configure(),
              icon: Icons.add,
            ),
            LTButton(
              label: '添加网站',
              onPressed: () => website(),
              style: LTButtonStyle.secondary,
            ),
            if (connecting || connection != null)
              LTButton(
                label: '断开连接',
                onPressed: disconnect,
                style: LTButtonStyle.danger,
              ),
            if (connection != null)
              LTButton(
                label: '刷新监控',
                loading: reading,
                onPressed: reading ? null : refresh,
                style: LTButtonStyle.secondary,
              ),
          ],
        ),
        if (connecting) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(error!),
          ),
        if (current != null) ...[
          const SizedBox(height: 16),
          Text(
            '${current.title} · ${connection?.connected == true ? 'SSH已连接' : 'SSH已断开'}',
          ),
          if (snapshot != null) ...[
            Text(
              'CPU：${snapshot!.cpuPercent?.toStringAsFixed(1) ?? '不可用'}% · 内存可用 ${snapshot!.memoryAvailableKB == null ? '不可用' : readableBytes(snapshot!.memoryAvailableKB! * 1024)} / ${snapshot!.memoryTotalKB == null ? '不可用' : readableBytes(snapshot!.memoryTotalKB! * 1024)}',
            ),
            Text(
              '根分区已用 ${snapshot!.diskUsedKB == null ? '不可用' : readableBytes(snapshot!.diskUsedKB! * 1024)} / ${snapshot!.diskTotalKB == null ? '不可用' : readableBytes(snapshot!.diskTotalKB! * 1024)}\n运行 ${snapshot!.uptimeSeconds?.toStringAsFixed(0) ?? '不可用'} 秒 · ${snapshot!.distro ?? '发行版不可用'}',
            ),
            for (final e in snapshot!.errors.entries)
              Text('${e.key}：${e.value}'),
            ExpansionTile(
              title: Text('Docker容器（只读）· ${snapshot!.docker.length}'),
              children: [
                TextButton(
                  onPressed: reading
                      ? null
                      : () => runUi(
                          context,
                          () => dockerRead(
                            "docker image ls --format '{{json .}}'",
                          ),
                        ),
                  child: const Text('镜像列表'),
                ),
                for (final container in snapshot!.docker)
                  ListTile(
                    trailing:
                        RegExp(r'^[a-f0-9]{12,64}$')
                            .hasMatch('${container['ID'] ?? ''}')
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '容器日志（200行）',
                                icon: const Icon(Icons.article_outlined),
                                onPressed: reading
                                    ? null
                                    : () => runUi(
                                        context,
                                        () => dockerRead(
                                          dockerReadCommand(
                                            'logs',
                                            '${container['ID']}',
                                          ),
                                        ),
                                      ),
                              ),
                              IconButton(
                                tooltip: '容器资源',
                                icon: const Icon(Icons.monitor_heart_outlined),
                                onPressed: reading
                                    ? null
                                    : () => runUi(
                                        context,
                                        () => dockerRead(
                                          dockerReadCommand(
                                            'stats',
                                            '${container['ID']}',
                                          ),
                                        ),
                                      ),
                              ),
                            ],
                          )
                        : null,
                    title: Text('${container['Names'] ?? '未命名'}'),
                    subtitle: Text(
                      '${container['Image'] ?? ''} · ${container['State'] ?? ''} · ${container['Status'] ?? ''}',
                    ),
                  ),
              ],
            ),
            TextButton(
              onPressed: () => runUi(
                context,
                () => ref
                    .read(memoryRepositoryProvider)
                    .createNote(
                      '${current.title} 故障/监控记录',
                      body: snapshot!.toMarkdown(),
                      source: 'server:${current.id}',
                      sensitive: true,
                    ),
                success: '监控快照已保存为敏感笔记。',
              ),
              child: const Text('保存此快照到记忆仓库'),
            ),
          ],
        ],
        if (websites.isNotEmpty)
          ExpansionTile(
            initiallyExpanded: true,
            title: const Text('网站状态'),
            children: [
              for (final site in websites)
                Builder(
                  builder: (context) {
                    final data = site.data['lastCheck'] as Map?;
                    return ListTile(
                      title: Text(site.title),
                      subtitle: Text(
                        '${site.text('url')}\n${data == null ? '尚未检查' : 'HTTP ${data['status'] ?? '不可用'} · ${data['elapsedMs']} ms\n最后检查 ${data['checkedAt']}\n证书到期 ${data['certificateExpires'] ?? '不可用（HTTP或TLS未成功）'}\n${data['error'] ?? ''}'}',
                      ),
                      onTap: () => website(site),
                      trailing: Wrap(
                        children: [
                          IconButton(
                            tooltip: '立即检测',
                            onPressed: checking.contains(site.id)
                                ? null
                                : () => checkWebsite(site),
                            icon: checking.contains(site.id)
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh),
                          ),
                          IconButton(
                            tooltip: '移除网站',
                            icon: const Icon(Icons.close),
                            onPressed: () async {
                              if (await ltConfirm(
                                    context,
                                    title: '移除网站监控？',
                                    message: site.title,
                                    confirmLabel: '移除',
                                  ) &&
                                  context.mounted) {
                                await runUi(
                                  context,
                                  () => ref
                                      .read(recordStoreProvider)
                                      .delete(site),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
      ],
      itemCount: servers.length,
      itemBuilder: (_, i) {
        final server = servers[i];
        final isCurrent = current?.id == server.id;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  server.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SelectableText(
                  '${server.text('username')}@${server.text('host')}:${server.number('port', 22)}\n${server.strings('tags').join(' · ')}\n${server.body}',
                ),
                Text(
                  server.text('hostKey').isEmpty
                      ? '尚未信任主机，首次连接需要核对指纹'
                      : '已固定指纹：${server.text('hostKey')}',
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    LTButton(
                      label: isCurrent ? '重新连接' : '连接SSH',
                      onPressed: connecting ? null : () => connect(server),
                    ),
                    LTButton(
                      label: '编辑',
                      onPressed: connecting || isCurrent
                          ? null
                          : () => configure(server),
                      style: LTButtonStyle.secondary,
                    ),
                    LTButton(
                      label: '重置指纹',
                      onPressed: connecting || isCurrent
                          ? null
                          : () async {
                              if (await ltConfirm(
                                    context,
                                    title: '移除已固定的主机指纹？',
                                    message:
                                        '只在已通过可信渠道确认服务器更换密钥时使用。下次连接将要求重新核对。',
                                    confirmLabel: '明确重置',
                                  ) &&
                                  context.mounted) {
                                await runUi(
                                  context,
                                  () =>
                                      repo.forgetHost(server, confirmed: true),
                                );
                              }
                            },
                      style: LTButtonStyle.ghost,
                    ),
                    LTButton(
                      label: '说明保存为笔记',
                      onPressed: () => runUi(
                        context,
                        () => ref
                            .read(memoryRepositoryProvider)
                            .createNote(
                              '${server.title} 配置说明',
                              body:
                                  '# ${server.title}\n\nSSH：${server.text('username')}@${server.text('host')}:${server.number('port', 22)}\n\n${server.body}\n\n主机指纹：${server.text('hostKey')}\n\n不包含密码或私钥。',
                              sensitive: true,
                              source: 'server:${server.id}',
                            ),
                        success: '配置说明已保存，不含凭据。',
                      ),
                      style: LTButtonStyle.ghost,
                    ),
                    LTButton(
                      label: '删除',
                      onPressed: connecting || isCurrent
                          ? null
                          : () async {
                              if (await ltConfirm(
                                    context,
                                    title: '删除服务器配置？',
                                    message: '删除本机配置和对应安全凭据，不对服务器执行命令。',
                                    confirmLabel: '删除',
                                  ) &&
                                  context.mounted) {
                                await runUi(context, () => repo.remove(server));
                              }
                            },
                      style: LTButtonStyle.danger,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
      empty: const LTEmptyState(
        title: '添加你自己的服务器',
        message: '暂未配置服务器；不会显示模拟CPU、内存或Docker数据。网站检测也可独立使用。',
        icon: Icons.dns_outlined,
      ),
    );
  }
}
