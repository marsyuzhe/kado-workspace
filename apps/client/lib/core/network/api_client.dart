import 'package:dio/dio.dart';

abstract interface class ApiClient {
  Future<Map<String, dynamic>> get(String path);
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body);
  void close();
}

class DioApiClient implements ApiClient {
  DioApiClient(Uri baseUri, {Dio? dio}) : _dio = dio ?? Dio() {
    if (baseUri.scheme != 'https' ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment) {
      throw ArgumentError(
        'API base URI must use HTTPS without credentials or query',
      );
    }
    _dio.options = BaseOptions(
      baseUrl: baseUri.toString(),
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      followRedirects: false,
    );
    // Deliberately no LogInterceptor: credentials and payloads must stay private.
  }
  final Dio _dio;

  void _validatePath(String path) {
    final uri = Uri.parse(path);
    // Uri.parse normalizes '..', so validate the original endpoint as well.
    final rawPath = path.split('?').first;
    final validEndpoint = RegExp(
      r'^/api/v1/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$',
    );
    if (!path.startsWith('/api/v1/') ||
        !validEndpoint.hasMatch(rawPath) ||
        path.startsWith('//') ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasFragment ||
        path.contains('\\')) {
      throw ArgumentError('Only relative /api/v1/ endpoints are permitted');
    }
  }

  @override
  Future<Map<String, dynamic>> get(String path) async {
    _validatePath(path);
    final response = await _dio.get<Map<String, dynamic>>(path);
    return response.data ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    _validatePath(path);
    final response = await _dio.post<Map<String, dynamic>>(path, data: body);
    return response.data ?? <String, dynamic>{};
  }

  @override
  void close() => _dio.close(force: true);
}
