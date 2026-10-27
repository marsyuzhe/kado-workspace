import 'package:flutter/material.dart';

import '../../core/ui/lt_components.dart';
import '../../shared/page_frame.dart';

class ComponentGallery extends StatefulWidget {
  const ComponentGallery({super.key});
  @override
  State<ComponentGallery> createState() => _ComponentGalleryState();
}

class _ComponentGalleryState extends State<ComponentGallery> {
  bool enabled = true;
  String choice = 'A';
  int section = 0;
  @override
  Widget build(BuildContext context) => PageFrame(
    eyebrow: 'DEVELOPMENT ONLY',
    title: '组件展示',
    description: '仅Debug构建可访问。交互组件沿用Flutter的键盘、焦点、触控与无障碍语义。',
    children: [
      LTToolbar(
        children: [
          LTButton(label: '主要操作', onPressed: () => ltMessage(context, '操作提示')),
          LTButton(
            label: '次要操作',
            style: LTButtonStyle.secondary,
            onPressed: () => ltMessage(context, '次要操作已触发'),
          ),
          const LTButton(label: '禁用'),
          const LTButton(label: '加载中', loading: true),
          LTButton(
            label: '确认对话框',
            style: LTButtonStyle.ghost,
            onPressed: () =>
                ltConfirm(context, title: '确认示例', message: '这是组件状态验证，不会修改数据。'),
          ),
        ],
      ),
      const SizedBox(height: 24),
      const LTTextField(label: '输入', hint: '中文、English、C:\\文件路径'),
      const SizedBox(height: 16),
      const LTSearchField(),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        initialValue: choice,
        decoration: const InputDecoration(labelText: '下拉选择'),
        items: const [
          DropdownMenuItem(value: 'A', child: Text('选项A')),
          DropdownMenuItem(value: 'B', child: Text('选项B')),
        ],
        onChanged: (v) => setState(() => choice = v!),
      ),
      SwitchListTile(
        title: const Text('开关'),
        value: enabled,
        onChanged: (v) => setState(() => enabled = v),
      ),
      CheckboxListTile(
        title: const Text('选择项'),
        value: enabled,
        onChanged: (v) => setState(() => enabled = v!),
      ),
      const LTSectionHeader('卡片、列表与状态'),
      const LTCard(
        child: ListTile(
          leading: Icon(Icons.description_outlined),
          title: Text('支持长文本、焦点与系统语义的列表'),
          subtitle: Text('可选的辅助说明'),
          trailing: LTBadge('状态'),
        ),
      ),
      const SizedBox(height: 16),
      LTDataTable(
        columns: const [
          DataColumn(label: Text('名称')),
          DataColumn(label: Text('状态')),
        ],
        rows: const [
          DataRow(cells: [DataCell(Text('组件')), DataCell(Text('已加载'))]),
        ],
      ),
      const SizedBox(height: 16),
      const LTSectionHeader('菜单、导航与任务进度示例'),
      Row(
        children: [
          PopupMenuButton<String>(
            tooltip: '菜单示例',
            onSelected: (v) => ltMessage(context, '已选择$v'),
            itemBuilder: (_) => const [
              PopupMenuItem(value: '编辑', child: Text('编辑示例')),
              PopupMenuItem(value: '复制', child: Text('复制示例')),
            ],
          ),
          const Tooltip(message: '支持键盘焦点的提示', child: Icon(Icons.info_outline)),
          TextButton(
            onPressed: () => ltMessage(context, '示例提示已显示'),
            child: const Text('显示提示'),
          ),
        ],
      ),
      DefaultTabController(
        length: 2,
        child: Column(
          children: const [
            TabBar(
              tabs: [
                Tab(text: '本地数据'),
                Tab(text: '任务记录'),
              ],
            ),
            SizedBox(
              height: 72,
              child: TabBarView(
                children: [
                  Center(child: Text('本地数据示例')),
                  Center(child: Text('任务记录示例')),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      const Text('任务进度示例：42%（展示组件状态）'),
      const LinearProgressIndicator(
        value: .42,
        semanticsLabel: '示例任务进度',
        semanticsValue: '42%',
      ),
      const SizedBox(height: 16),
      LayoutBuilder(
        builder: (context, c) => c.maxWidth > 600
            ? SizedBox(
                height: 200,
                child: Row(
                  children: [
                    NavigationRail(
                      selectedIndex: section,
                      onDestinationSelected: (v) => setState(() => section = v),
                      labelType: NavigationRailLabelType.all,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.home_outlined),
                          label: Text('主页'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.folder_outlined),
                          label: Text('资料'),
                        ),
                      ],
                    ),
                    Expanded(
                      child: Center(
                        child: Text(section == 0 ? '主页示例' : '资料示例'),
                      ),
                    ),
                  ],
                ),
              )
            : NavigationBar(
                selectedIndex: section,
                onDestinationSelected: (v) => setState(() => section = v),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined),
                    label: '主页',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    label: '资料',
                  ),
                ],
              ),
      ),
      const SizedBox(height: 16),
      const LTEmptyState(title: '暂无内容', message: '创建第一条记录后会显示在这里。'),
      const LTLoadingState(),
      LTErrorState(onRetry: () => ltMessage(context, '重试已触发')),
    ],
  );
}
