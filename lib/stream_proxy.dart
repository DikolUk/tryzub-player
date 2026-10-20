import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'api_service.dart';

/// Локальний проксі-сервер для стабільного стрімінгу аудіо на Android та інших ОС.
/// Вирішує проблеми рідного Android MediaPlayer:
/// - Автоматично додає обов'язкові авторизаційні заголовки (User-Agent, X-App-Token, Authorization)
/// - Підтримує TLS 1.3 та обхід блокувань за User-Agent
/// - Підтримує Range-запити для швидкої перемотки треків
/// - Працює напряму через 127.0.0.1 без таймаутів
class StreamProxy {
  static HttpServer? _server;
  static int _port = 0;
  static final HttpClient _client = HttpClient()
    ..badCertificateCallback = ((X509Certificate cert, String host, int port) => true)
    ..connectionTimeout = const Duration(seconds: 15);

  static int get port => _port;

  static Future<void> init() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      debugPrint('[StreamProxy] Запущено локальний стрім-проксі на 127.0.0.1:$_port');
      _server!.listen(_handleRequest, onError: (e) {
        debugPrint('[StreamProxy] Помилка сервера: $e');
      });
    } catch (e) {
      debugPrint('[StreamProxy] Не вдалося запустити локальний проксі: $e');
    }
  }

  /// Повертає локальний URL для відтворення треку
  static String getStreamUrl(int trackId) {
    final token = ApiService.token ?? '';
    if (_port == 0) {
      // Якщо локальний проксі ще не стартував, повертаємо прямий URL з екрануванням
      return '${ApiService.baseUrl}/stream.php?id=$trackId&token=${Uri.encodeComponent(token)}';
    }
    return 'http://127.0.0.1:$_port/stream?id=$trackId&token=${Uri.encodeComponent(token)}';
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    try {
      final trackId = request.uri.queryParameters['id'];
      final token = request.uri.queryParameters['token'] ?? ApiService.token ?? '';

      if (trackId == null || trackId.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final targetUrl = Uri.parse(
        '${ApiService.baseUrl}/stream.php?id=$trackId&token=${Uri.encodeComponent(token)}',
      );

      final clientReq = await _client.getUrl(targetUrl);

      // Додаємо повні заголовки застосунку
      clientReq.headers.set('User-Agent', 'TryzubPlayer-Multiplatform/${ApiService.appVersion}');
      clientReq.headers.set('X-App-Version', ApiService.appVersion);
      if (token.isNotEmpty) {
        clientReq.headers.set('Authorization', 'Bearer $token');
        clientReq.headers.set('X-App-Token', token);
      }

      // Передаємо Range-запит від Android MediaPlayer для перемотки
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        clientReq.headers.set(HttpHeaders.rangeHeader, range);
      }

      final clientResp = await clientReq.close();

      request.response.statusCode = clientResp.statusCode;

      // Передаємо заголовки відповіді від сервера
      clientResp.headers.forEach((name, values) {
        for (final val in values) {
          request.response.headers.add(name, val);
        }
      });

      // Забезпечуємо коректний Content-Type для Android MediaPlayer
      if (request.response.headers.value(HttpHeaders.contentTypeHeader) == null ||
          request.response.headers.value(HttpHeaders.contentTypeHeader)!.contains('text/html')) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');
      }

      request.response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');

      await clientResp.pipe(request.response);
    } catch (e) {
      debugPrint('[StreamProxy] Помилка обробки стріму: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  static Future<void> stop() async {
    try {
      await _server?.close(force: true);
      _server = null;
      _port = 0;
    } catch (_) {}
  }
}
