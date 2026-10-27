import 'dart:convert';

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import 'api_studio_service.dart';

String normalizeRepository(String input) {
  var text = input.trim();
  if (text.startsWith('https://')) {
    final uri = Uri.parse(text);
    if (uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.pathSegments.length != 2) {
      throw const ToolFailure('请输入github.com的仓库根地址。');
    }
    text = uri.pathSegments.join('/');
  }
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$')
          .hasMatch(text) ||
      {'.', '..'}.contains(text.split('/').last)) {
    throw const ToolFailure('仓库格式为owner/repo。');
  }
  return text;
}

/// Public, manual, token-free REST access. No clone, script execution, login,
/// repository mutation or background refresh. API errors remain visible.
class GitHubProjectService {
  GitHubProjectService(this.store, this.api);
  final RecordStore store;
  final ApiStudioService api;
  Future<Map<String, dynamic>> fetch(String input) async {
    final repo = normalizeRepository(input),
        headers = {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2026-03-10',
          'User-Agent': 'KADO-Desk',
        };
    Future<Object?> get(String suffix) async {
      final response = await api.send(
        ApiRequestSpec(
          url: 'https://api.github.com/repos/$repo$suffix',
          headers: headers,
        ),
      );
      if (response.status != 200) {
        throw ToolFailure(
          'GitHub HTTP ${response.status}：检查公开访问、网络或限流；没有自动请求Token。',
        );
      }
      return jsonDecode(response.body);
    }

    final info = await get('') as Map,
        releases = await get('/releases?per_page=10') as List;
    String bounded(Object? value, int max) {
      final s = '${value ?? ''}';
      return s.substring(0, s.length.clamp(0, max));
    }

    return {
      'repository': repo,
      'description': bounded(info['description'], 1000),
      'language': bounded(info['language'], 100),
      'stars': info['stargazers_count'],
      'issues': info['open_issues_count'],
      'defaultBranch': bounded(info['default_branch'], 200),
      'releases': [
        for (final raw in releases.take(10))
          if (raw is Map)
            {
              'tag': bounded(raw['tag_name'], 200),
              'name': bounded(raw['name'], 300),
              'publishedAt': bounded(raw['published_at'], 100),
            },
      ],
      'fetchedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<ToolRecord> save(
    String input, {
    String localPath = '',
    Map<String, dynamic>? snapshot,
    ToolRecord? existing,
  }) async {
    final repo = normalizeRepository(input);
    existing ??= await store.find('github_project', 'repository', repo);
    final data = {
      ...existing?.data ?? {},
      'repository': repo,
      'localPath': localPath,
      'snapshot': ?snapshot,
      'favorite': true,
      'syncAllowed': false,
    };
    return existing == null
        ? store.create('github_project', repo, data: data)
        : store.save(existing.copyWith(title: repo, data: data));
  }
}
