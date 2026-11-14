import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api_exception.dart';

/// Клиент цехового сервера: адрес, токены сеанса, запросы JSON и кадров камеры, перевод отказов в [KvApiException].
///
/// Токен доступа живёт 30 минут: при ответе 401 клиент один раз обновляет пару токенов и повторяет запрос.
class ApiClient {
  /// Создаёт клиент сервера с адресом [baseUrl].
  ApiClient(this.baseUrl, {http.Client? client}) : _http = client ?? http.Client();

  /// Адрес сервера без косой черты в конце.
  final String baseUrl;

  final http.Client _http;

  /// Токен доступа текущего сеанса.
  String? accessToken;

  /// Токен обновления текущего сеанса.
  String? refreshToken;

  /// Последний кадр камеры в JPEG: прикладывается к находке, которую инженер фиксирует со сканера.
  Uint8List? lastFrame;

  /// Сколько ждать ответа сервера.
  static const Duration timeout = Duration(seconds: 12);

  Future<bool>? _refreshing;

  /// Адрес запроса к пути [path] с параметрами [query].
  Uri uri(String path, [Map<String, String>? query]) {
    final Uri base = Uri.parse('$baseUrl$path');
    return query == null || query.isEmpty ? base : base.replace(queryParameters: query);
  }

  /// Адрес WebSocket к пути [path] с токеном доступа в параметре token.
  Uri ws(String path) {
    final Uri base = Uri.parse('$baseUrl$path');
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', queryParameters: {'token': accessToken ?? ''});
  }

  /// Ключ приложения для сервера за паролем сайта; задаётся при сборке (--dart-define=KST_APP_KEY=...).
  static const String appKey = String.fromEnvironment('KST_APP_KEY');

  /// Заголовок ключа приложения: передаётся в каждом запросе и при открытии WebSocket.
  static Map<String, String> get appHeaders => appKey.isEmpty ? const <String, String>{} : const {'X-KST-App': appKey};

  /// Заголовки открытия WebSocket.
  Map<String, String> get wsHeaders => appHeaders;

  Map<String, String> get _headers => {
        ...appHeaders,
        'accept': 'application/json',
        if (accessToken != null) 'authorization': 'Bearer $accessToken',
      };

  /// GET с ответом JSON.
  Future<dynamic> getJson(String path, [Map<String, String>? query]) => _send(() => _http.get(uri(path, query), headers: _headers));

  /// POST с телом JSON [body] и ответом JSON; [auth] = false - без токена (вход).
  Future<dynamic> postJson(String path, [Object? body, bool auth = true]) => _send(
        () => _http.post(
          uri(path),
          headers: {...auth ? _headers : {...appHeaders, 'accept': 'application/json'}, 'content-type': 'application/json'},
          body: jsonEncode(body ?? const <String, Object>{}),
        ),
        retry: auth,
      );

  /// POST формы multipart с полями [fields] и кадром JPEG [frame] в поле frame.
  Future<dynamic> postForm(String path, {Map<String, String> fields = const {}, Uint8List? frame}) => _send(() async {
        final http.MultipartRequest req = http.MultipartRequest('POST', uri(path))
          ..headers.addAll(_headers)
          ..fields.addAll(fields);
        if (frame != null) {
          req.files.add(http.MultipartFile.fromBytes('frame', frame, filename: 'frame.jpg'));
        }
        return http.Response.fromStream(await _http.send(req));
      });

  /// GET файла: байты ответа (отчёт PDF или Excel).
  Future<Uint8List> getBytes(String path) async {
    http.Response res = await _guard(() => _http.get(uri(path), headers: _headers));
    if (res.statusCode == 401 && refreshToken != null && await _refresh()) {
      res = await _guard(() => _http.get(uri(path), headers: _headers));
    }
    if (res.statusCode != 200) {
      throw failureOf(res.statusCode, _detail(res));
    }
    return res.bodyBytes;
  }

  /// Проверка связи: время ответа /health в миллисекундах.
  Future<int> ping() async {
    final Stopwatch w = Stopwatch()..start();
    await _send(() => _http.get(uri('/health'), headers: appHeaders), retry: false);
    return w.elapsedMilliseconds;
  }

  Future<dynamic> _send(Future<http.Response> Function() request, {bool retry = true}) async {
    http.Response res = await _guard(request);
    if (res.statusCode == 401 && retry && refreshToken != null && await _refresh()) {
      res = await _guard(request);
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.bodyBytes.isEmpty) {
        return null;
      }
      return jsonDecode(utf8.decode(res.bodyBytes));
    }
    throw failureOf(res.statusCode, _detail(res));
  }

  Future<http.Response> _guard(Future<http.Response> Function() request) async {
    try {
      return await request().timeout(timeout);
    } on TimeoutException {
      throw const KvApiException(KvFailure.network, 'Цеховой сервер не отвечает');
    } on SocketException {
      throw const KvApiException(KvFailure.network, 'Нет связи с цеховым сервером');
    } on http.ClientException {
      throw const KvApiException(KvFailure.network, 'Нет связи с цеховым сервером');
    } on HandshakeException {
      throw const KvApiException(KvFailure.network, 'Нет связи с цеховым сервером');
    }
  }

  /// Обновляет пару токенов; одновременные запросы ждут одного обновления.
  Future<bool> _refresh() => _refreshing ??= () async {
        try {
          final http.Response res = await _guard(
            () => _http.post(
              uri('/auth/refresh'),
              headers: {...appHeaders, 'content-type': 'application/json'},
              body: jsonEncode({'refresh_token': refreshToken}),
            ),
          );
          if (res.statusCode != 200) {
            return false;
          }
          final Map<String, dynamic> j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
          accessToken = j['access_token'] as String?;
          refreshToken = j['refresh_token'] as String?;
          return accessToken != null;
        } on KvApiException {
          return false;
        } finally {
          _refreshing = null;
        }
      }();

  /// Обновить токены сейчас (перед подключением WebSocket после долгой паузы).
  Future<bool> refreshNow() => refreshToken == null ? Future<bool>.value(false) : _refresh();

  static String _detail(http.Response res) {
    try {
      final dynamic j = jsonDecode(utf8.decode(res.bodyBytes));
      final dynamic d = j is Map<String, dynamic> ? j['detail'] : null;
      if (d is String) {
        return d;
      }
      if (d is List && d.isNotEmpty && d.first is Map && (d.first as Map)['msg'] != null) {
        return (d.first as Map)['msg'].toString();
      }
    } on FormatException {
      return 'Ошибка сервера ${res.statusCode}';
    }
    return 'Ошибка сервера ${res.statusCode}';
  }

  /// Вид отказа по коду ответа сервера [status] и тексту [detail].
  static KvApiException failureOf(int status, String detail) => switch (status) {
        401 => KvApiException(KvFailure.invalidCredentials, detail),
        403 when detail.contains('аблокир') => KvApiException(KvFailure.blocked, detail),
        403 => KvApiException(KvFailure.forbidden, detail),
        404 => KvApiException(KvFailure.notFound, detail),
        422 || 400 || 409 => KvApiException(KvFailure.validation, detail),
        429 || 423 => KvApiException(KvFailure.locked, detail),
        _ => KvApiException(KvFailure.network, detail),
      };

  /// Закрыть соединения.
  void close() => _http.close();
}
