import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';
import '../../shared/record_ui.dart';
import 'dev_tool_widgets.dart';
import 'network_inspector_service.dart';

class NetworkInspectorPage extends StatefulWidget {
  const NetworkInspectorPage({super.key});
  @override
  State<NetworkInspectorPage> createState() => _NetworkInspectorPageState();
}

class _NetworkInspectorPageState extends State<NetworkInspectorPage> {
  final host = TextEditingController(),
      port = TextEditingController(text: '443'),
      timeout = TextEditingController(text: '3');
  String protocol = 'tcp', output = '';
  bool busy = false;
  @override
  void dispose() {
    host.dispose();
    port.dispose();
    timeout.dispose();
    super.dispose();
  }

  Future<void> run(Future<Object?> Function() action) async {
    setState(() => busy = true);
    try {
      final result = await action();
      if (mounted) {
        setState(
          () => output = result is String
              ? result
              : const JsonEncoder.withIndent('  ').convert(result),
        );
      }
    } catch (error) {
      if (mounted) setState(() => output = '检查失败：$error');
      rethrow;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'SYSTEM & NETWORK',
    title: 'Network Inspector',
    description: '仅诊断你明确输入的单个地址。HTTPS选项检查TLS证书，不发送HTTP请求或凭据。',
    children: [
      LTTextField(controller: host, label: '主机（IP / DNS，不含协议与路径）'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: 120,
            child: LTTextField(controller: port, label: '端口'),
          ),
          SizedBox(
            width: 120,
            child: LTTextField(controller: timeout, label: '超时（秒）'),
          ),
          DropdownMenu<String>(
            initialSelection: protocol,
            label: const Text('协议'),
            dropdownMenuEntries: [
              for (final p in ['dns', 'tcp', 'http', 'https'])
                DropdownMenuEntry(value: p, label: p.toUpperCase()),
            ],
            onSelected: (v) => setState(() => protocol = v!),
          ),
        ],
      ),
      LTToolbar(
        children: [
          LTButton(
            label: '检查指定地址',
            onPressed: busy
                ? null
                : () => runUi(
                    context,
                    () => run(
                      () => NetworkInspectorService().check(
                        host.text,
                        int.tryParse(port.text) ?? 0,
                        protocol,
                        timeout: Duration(
                          seconds: int.tryParse(timeout.text) ?? 0,
                        ),
                      ),
                    ),
                  ),
          ),
          TextButton(
            onPressed: busy
                ? null
                : () => runUi(
                    context,
                    () => run(NetworkInspectorService().interfaces),
                  ),
            child: const Text('本机网络接口'),
          ),
          if (Platform.isWindows)
            TextButton(
              onPressed: busy
                  ? null
                  : () => runUi(
                      context,
                      () => run(NetworkInspectorService().windowsConnections),
                    ),
              child: const Text('本机连接 / 监听端口'),
            ),
          TextButton(
            onPressed: output.isEmpty ? null : () => copyDevText(output),
            child: const Text('复制结果'),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (output.isNotEmpty) DevOutput(text: output),
    ],
  );
}
