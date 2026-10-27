import 'version.dart';

/// 只集中可见品牌；系统包标识、数据库和凭据身份不随显示名改变。
class AppBrandConfig {
  const AppBrandConfig({
    required this.appDisplayName,
    required this.appShortName,
    required this.appDescription,
    required this.authorName,
    required this.version,
    required this.copyrightText,
    required this.brandAssetPath,
    this.websiteUrl = '',
    this.repositoryUrl = '',
  });
  final String appDisplayName,
      appShortName,
      appDescription,
      authorName,
      version,
      websiteUrl,
      repositoryUrl,
      copyrightText,
      brandAssetPath;
  String get authorCredit => 'Created by $authorName';
  // Generated display constants from config/brand.json; IDs remain unchanged.
  static const displayName = 'KADO Desk',
      shortName = 'KADO',
      description = '个人数字工作台';
  static const author = 'Links Tam',
      credit = 'Created by Links Tam',
      legal = '© 2026 Links Tam';
  static const iconAsset = 'assets/brand/app_icon_1024.png';
  static const current = AppBrandConfig(
    appDisplayName: displayName,
    appShortName: shortName,
    appDescription: description,
    authorName: author,
    version: appVersion,
    copyrightText: legal,
    brandAssetPath: iconAsset,
  );
  static const subtitle = 'Personal Workspace';
  static const moduleNames = {
    'hub': '工作台',
    'archive': '文件管理',
    'clipboard': '剪贴板',
    'ai_desk': 'AI 控制台',
    'server': '服务器',
    'memory': '知识仓库',
    'studio': '像素办公室',
    'utilities': '工具中心',
    'bookmarks': '网站导航',
    'converter': '格式转换',
    'renamer': '批量重命名',
    'image_studio': '图片处理',
    'transcribe': '语音转文字',
    'media_library': '视频素材',
    'software_library': '安装包管理',
    'environment_snapshot': '环境快照',
    'lan_transfer': '局域网互传',
    'home_dashboard': '家庭设备',
    'game_saves': '游戏存档',
    'finance': '记账分析',
    'collection_cards': '收藏卡',
    'timeline': '个人日程',
    'utility_jobs': '工具任务',
  };
}
