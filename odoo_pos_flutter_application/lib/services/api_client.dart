import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_config.dart';

/// Small API response model kept in the same file as requested.
/// It is optional for callers; raw [http.Response] is still returned by request().
class ApiJsonResponse {
  final int statusCode;
  final Map<String, String> headers;
  final dynamic body;
  final bool refreshedToken;

  const ApiJsonResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    this.refreshedToken = false,
  });

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  Map<String, dynamic> get asMap {
    if (body is Map<String, dynamic>) return body as Map<String, dynamic>;
    return <String, dynamic>{};
  }
}

/// Central HTTP helper for Odoo API calls.
///
/// It obtains a valid JWT, attaches `Authorization: Bearer <token>`, and if the
/// server still returns 401, it re-authenticates once and retries the same call.
class ApiClient {
  ApiClient._();

  static const Duration defaultTimeout = Duration(seconds: 15);

  static Future<String> get baseUrl async {
    final url = await AppConfig.getServerUrl();
    if (url.isEmpty) {
      throw Exception(
          'Server URL is not configured. Please set it in Settings.');
    }
    return url;
  }

  static Future<http.Response> get(
    String path, {
    Map<String, String>? headers,
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) {
    return request(
      'GET',
      path,
      headers: headers,
      authenticated: authenticated,
      timeout: timeout,
    );
  }

  static Future<http.Response> post(
    String path, {
    Map<String, String>? headers,
    Object? body,
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) {
    return request(
      'POST',
      path,
      headers: headers,
      body: body,
      authenticated: authenticated,
      timeout: timeout,
    );
  }

  static Future<http.Response> put(
    String path, {
    Map<String, String>? headers,
    Object? body,
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) {
    return request(
      'PUT',
      path,
      headers: headers,
      body: body,
      authenticated: authenticated,
      timeout: timeout,
    );
  }

  static Future<http.Response> delete(
    String path, {
    Map<String, String>? headers,
    Object? body,
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) {
    return request(
      'DELETE',
      path,
      headers: headers,
      body: body,
      authenticated: authenticated,
      timeout: timeout,
    );
  }

  static Future<ApiJsonResponse> json(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) async {
    final response = await request(
      method,
      path,
      headers: headers,
      body: body,
      authenticated: authenticated,
      timeout: timeout,
    );

    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = response.body;
    }

    return ApiJsonResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      body: decoded,
    );
  }

  static Future<http.Response> request(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
    bool authenticated = true,
    Duration timeout = defaultTimeout,
  }) async {
    final response = await _send(
      method,
      path,
      headers: headers,
      body: body,
      authenticated: authenticated,
      forceRefresh: false,
      timeout: timeout,
    );

    if (authenticated && response.statusCode == 401) {
      // Do not clear the stored token here. Another parallel request may have
      // already refreshed and saved a newer token. refreshApiToken() has its own
      // guard and will overwrite/clear the token safely based on auth result.
      return _send(
        method,
        path,
        headers: headers,
        body: body,
        authenticated: authenticated,
        forceRefresh: true,
        timeout: timeout,
      );
    }

    return response;
  }

  static Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? headers,
    Object? body,
    required bool authenticated,
    required bool forceRefresh,
    required Duration timeout,
  }) async {
    final url = await _resolveUrl(path);
    final requestHeaders = <String, String>{...?headers};

    if (authenticated) {
      final token = forceRefresh
          ? await AppConfig.refreshApiToken()
          : await AppConfig.getApiToken();
      if (token.isEmpty) {
        throw Exception('Authentication failed. Please reconnect to Odoo.');
      }
      requestHeaders['Authorization'] = 'Bearer $token';
    }

    if (body != null && !requestHeaders.containsKey('Content-Type')) {
      requestHeaders['Content-Type'] = 'application/json';
    }

    final normalizedMethod = method.toUpperCase();
    final encodedBody =
        body is String || body == null ? body : jsonEncode(body);

    switch (normalizedMethod) {
      case 'GET':
        return http.get(url, headers: requestHeaders).timeout(timeout);
      case 'POST':
        return http
            .post(url, headers: requestHeaders, body: encodedBody)
            .timeout(timeout);
      case 'PUT':
        return http
            .put(url, headers: requestHeaders, body: encodedBody)
            .timeout(timeout);
      case 'DELETE':
        return http
            .delete(url, headers: requestHeaders, body: encodedBody)
            .timeout(timeout);
      default:
        throw UnsupportedError('Unsupported HTTP method: $method');
    }
  }

  static Future<Uri> _resolveUrl(String path) async {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return Uri.parse(path);
    }

    final root = await baseUrl;
    final cleanRoot =
        root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$cleanRoot$cleanPath');
  }
}
