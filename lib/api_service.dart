import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrackModel {
  final int id;
  final String title;
  final String artist;
  final String fileName;
  final String coverImage;
  final int playCount;
  final int downloadCount;
  final String createdAt;

  TrackModel({
    required this.id,
    required this.title,
    required this.artist,
    required this.fileName,
    required this.coverImage,
    required this.playCount,
    required this.downloadCount,
    required this.createdAt,
  });

  factory TrackModel.fromJson(Map<String, dynamic> json) {
    return TrackModel(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? 'Без назви',
      artist: json['artist'] as String? ?? 'Тризуб МС',
      fileName: json['file_name'] as String? ?? '',
      coverImage: json['cover_image'] as String? ?? '',
      playCount: json['play_count'] as int? ?? 0,
      downloadCount: json['download_count'] as int? ?? 0,
      createdAt: json['created_at'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'file_name': fileName,
        'cover_image': coverImage,
        'play_count': playCount,
        'download_count': downloadCount,
        'created_at': createdAt,
      };

  String get coverUrl {
    if (coverImage.isEmpty) {
      return 'https://tryzubmc-official.top/logo.jpg';
    }
    return 'https://tryzubmc-official.top/uploads/covers/$coverImage';
  }
}

class UserProfileModel {
  final int id;
  final String username;
  final String email;
  final String plan;
  final bool isUnlimited;
  final int weeklyLimit;
  final int weeklyCount;
  final int remainingDownloads;
  final int daysUntilReset;

  UserProfileModel({
    required this.id,
    required this.username,
    required this.email,
    required this.plan,
    required this.isUnlimited,
    required this.weeklyLimit,
    required this.weeklyCount,
    required this.remainingDownloads,
    required this.daysUntilReset,
  });

  factory UserProfileModel.fromJson(Map<String, dynamic> json) {
    return UserProfileModel(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      email: json['email'] as String? ?? '',
      plan: json['plan'] as String? ?? 'free',
      isUnlimited: json['is_unlimited'] as bool? ?? false,
      weeklyLimit: json['weekly_limit'] as int? ?? 5,
      weeklyCount: json['weekly_count'] as int? ?? 0,
      remainingDownloads: json['remaining_downloads'] as int? ?? 5,
      daysUntilReset: json['days_until_reset'] as int? ?? 7,
    );
  }
}

class ApiService {
  static const String baseUrl = 'https://tryzubmc-official.top';
  static const String appVersion = '2.4';

  static String? _token;
  static UserProfileModel? currentUser;

  static String? get token => _token;
  static bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  static Map<String, String> get _headers => {
        'User-Agent': 'TryzubPlayer-Multiplatform/$appVersion',
        'X-App-Version': appVersion,
        'Accept': 'application/json',
        if (_token != null && _token!.isNotEmpty) ...{
          'Authorization': 'Bearer $_token',
          'X-App-Token': _token!,
        },
      };

  static Future<void> initSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('tryzub_auth_token');
    if (_token != null && _token!.isNotEmpty) {
      await fetchProfile();
    }
  }

  static Future<void> saveToken(String newToken) async {
    _token = newToken;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tryzub_auth_token', newToken);
    await fetchProfile();
  }

  static Future<void> logout() async {
    _token = null;
    currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('tryzub_auth_token');
  }

  /// Отримання списку всіх 120 треків з кешуванням для офлайн-режиму
  static Future<List<TrackModel>> getTracks() async {
    final uri = Uri.parse('$baseUrl/api/tracks.php');
    try {
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        List<dynamic> list = [];
        if (decoded is List) {
          list = decoded;
        } else if (decoded is Map && decoded['success'] == true && decoded['tracks'] is List) {
          list = decoded['tracks'] as List;
        }

        final tracks = list.map((e) => TrackModel.fromJson(e as Map<String, dynamic>)).toList();
        if (tracks.isNotEmpty) {
          // Зберігаємо в локальний кеш
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cached_tracks_json', jsonEncode(list));
          return tracks;
        }
      }
    } catch (_) {}

    // Fallback до локального кешу
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('cached_tracks_json');
    if (cached != null) {
      try {
        final list = jsonDecode(cached) as List;
        return list.map((e) => TrackModel.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {}
    }
    return [];
  }

  /// Посилання на потокове відтворення (аудіо стрім)
  static String getStreamUrl(int trackId) {
    final t = _token ?? '';
    return '$baseUrl/stream.php?id=$trackId&token=$t';
  }

  /// Вхід за логіном і паролем
  static Future<Map<String, dynamic>> login(String username, String password) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: {
          'action': 'login',
          'login': username,
          'username': username,
          'password': password,
          'device_name': 'Tryzub Multiplatform Player',
        },
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Перевірка 2FA (Telegram) коду
  static Future<Map<String, dynamic>> check2FA(String code) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: {
          'action': 'check_2fa',
          'code': code,
          'device_name': 'Tryzub Multiplatform Player',
        },
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true && data['status'] == 'approved' && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Авторизація через Telegram-бота
  static Future<Map<String, dynamic>> tgStart() async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: {'action': 'tg_start'},
      ).timeout(const Duration(seconds: 10));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> tgCheck(String authTicket) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: {
          'action': 'tg_check',
          'token': authTicket,
          'device_name': 'Tryzub Multiplatform Player',
        },
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true && data['status'] == 'approved' && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Оновлення профілю користувача та лімітів
  static Future<UserProfileModel?> fetchProfile() async {
    if (!isAuthenticated) return null;
    final uri = Uri.parse('$baseUrl/api/app_profile.php?token=${_token!}');
    try {
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['success'] == true && data['user'] is Map) {
          currentUser = UserProfileModel.fromJson(data['user'] as Map<String, dynamic>);
          return currentUser;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Інформація про оплату / підписку та реквізити підтримки
  static Future<Map<String, dynamic>> getPaymentInfo() async {
    final uri = Uri.parse('$baseUrl/api/payment_info.php');
    try {
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  /// Завантаження MP3 файлу на диск
  static Future<String?> downloadTrack(TrackModel track, {Function(double)? onProgress}) async {
    final t = _token ?? '';
    final url = '$baseUrl/api/app_download.php?track_id=${track.id}&id=${track.id}&token=$t';

    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(_headers);

      final response = await http.Client().send(req);
      if (response.statusCode != 200) return null;

      final total = response.contentLength ?? 0;
      int received = 0;

      final dir = await getApplicationDocumentsDirectory();
      final targetDir = Directory('${dir.path}/Tryzub_Music');
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }

      final fileName = track.fileName.isNotEmpty ? track.fileName : 'track_${track.id}.mp3';
      final file = File('${targetDir.path}/$fileName');
      final sink = file.openWrite();

      await response.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      }).asFuture();

      await sink.close();
      await fetchProfile(); // Оновлюємо ліміти завантажень
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
