import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrackModel {
  final int id;
  final String title;
  final String artist;
  final String fileName;
  final String? coverImage;
  final int playCount;
  final int downloadCount;
  final String createdAt;

  TrackModel({
    required this.id,
    required this.title,
    required this.artist,
    required this.fileName,
    this.coverImage,
    required this.playCount,
    required this.downloadCount,
    required this.createdAt,
  });

  factory TrackModel.fromJson(Map<String, dynamic> json) {
    return TrackModel(
      id: json['id'] is int ? json['id'] as int : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      title: json['title'] as String? ?? 'Без назви',
      artist: json['artist'] as String? ?? 'Тризуб МС',
      fileName: json['file_name'] as String? ?? '',
      coverImage: json['cover_image'] as String?,
      playCount: json['play_count'] is int ? json['play_count'] as int : int.tryParse(json['play_count']?.toString() ?? '0') ?? 0,
      downloadCount: json['download_count'] is int ? json['download_count'] as int : int.tryParse(json['download_count']?.toString() ?? '0') ?? 0,
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
    if (coverImage == null || coverImage!.isEmpty) {
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
      id: json['id'] is int ? json['id'] as int : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      username: json['username'] as String? ?? '',
      email: json['email'] as String? ?? '',
      plan: json['plan'] as String? ?? 'free',
      isUnlimited: json['is_unlimited'] as bool? ?? false,
      weeklyLimit: json['weekly_limit'] is int ? json['weekly_limit'] as int : int.tryParse(json['weekly_limit']?.toString() ?? '5') ?? 5,
      weeklyCount: json['weekly_count'] is int ? json['weekly_count'] as int : int.tryParse(json['weekly_count']?.toString() ?? '0') ?? 0,
      remainingDownloads: json['remaining_downloads'] is int
          ? (json['remaining_downloads'] as int)
          : int.tryParse(json['remaining_downloads']?.toString() ?? '0') ?? 0,
      daysUntilReset: json['days_until_reset'] is int ? json['days_until_reset'] as int : int.tryParse(json['days_until_reset']?.toString() ?? '0') ?? 0,
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

  static String get deviceName {
    if (kIsWeb) return 'Web Client';
    if (Platform.isIOS) return 'iOS App';
    if (Platform.isAndroid) return 'Android App';
    if (Platform.isWindows) return 'Windows Player';
    if (Platform.isMacOS) return 'macOS App';
    if (Platform.isLinux) return 'Linux App';
    return 'Official Client';
  }

  static Map<String, String> get _headers => {
        'User-Agent': 'TryzubPlayer-Multiplatform/$appVersion',
        'X-App-Version': appVersion,
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
        if (_token != null && _token!.isNotEmpty) ...{
          'Authorization': 'Bearer $_token',
          'X-App-Token': _token!,
        },
      };

  static Future<void> initSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString('tryzub_auth_token');
      if (_token != null && _token!.isNotEmpty) {
        // Оновлюємо профіль у фоні, щоб не затримувати запуск застосунку на сплеш-скріні
        fetchProfile().catchError((_) => null);
      }
    } catch (_) {}
  }

  static Future<void> saveToken(String newToken) async {
    _token = newToken;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tryzub_auth_token', newToken);
    await fetchProfile();
  }

  static Future<void> logout() async {
    if (_token != null) {
      try {
        final uri = Uri.parse('$baseUrl/api/app_auth.php');
        await http.post(
          uri,
          headers: _headers,
          body: jsonEncode({'action': 'logout', 'token': _token}),
        ).timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    _token = null;
    currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('tryzub_auth_token');
  }

  /// Отримання списку треків
  static Future<List<TrackModel>> getTracks() async {
    final uri = Uri.parse('$baseUrl/api/tracks.php');
    try {
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 10));
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
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cached_tracks_json', jsonEncode(list));
          return tracks;
        }
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('cached_tracks_json');
    if (cached != null) {
      try {
        final list = jsonDecode(cached) as List;
        return list.map((e) => TrackModel.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {}
    }

    // Fallback: перевіряємо локальний кеш зі старого плеєра (~/.config/tryzub-player/tracks_cache.json)
    try {
      final home = Platform.environment['HOME'] ?? '';
      final legacyCache = File('$home/.config/tryzub-player/tracks_cache.json');
      if (await legacyCache.exists()) {
        final content = await legacyCache.readAsString();
        final list = jsonDecode(content) as List;
        final tracks = list.map((e) => TrackModel.fromJson(e as Map<String, dynamic>)).toList();
        if (tracks.isNotEmpty) {
          await prefs.setString('cached_tracks_json', content);
          return tracks;
        }
      }
    } catch (_) {}

    return [];
  }

  /// Посилання на аудіо стрім
  static String getStreamUrl(int trackId) {
    final t = _token ?? '';
    return '$baseUrl/stream.php?id=$trackId&token=$t';
  }

  /// Вхід за логіном і паролем (з підтримкою 2FA)
  static Future<Map<String, dynamic>> login(String username, String password) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'action': 'login',
          'login': username,
          'username': username,
          'password': password,
          'device_name': deviceName,
        }),
      ).timeout(const Duration(seconds: 12));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': 'Помилка мережі: $e'};
    }
  }

  /// Перевірка 2FA коду
  static Future<Map<String, dynamic>> check2FA(String code) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'action': 'check_2fa',
          'code': code,
          'device_name': deviceName,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['status'] == 'approved' && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Скасування очікування 2FA
  static Future<void> cancel2FA(String code) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({'action': 'cancel_2fa', 'code': code}),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// Початок авторизації через Telegram-бота
  static Future<Map<String, dynamic>> tgStart() async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({'action': 'tg_start'}),
      ).timeout(const Duration(seconds: 10));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Перевірка статусу авторизації через Telegram
  static Future<Map<String, dynamic>> tgCheck(String ticketToken) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'action': 'tg_check',
          'token': ticketToken,
          'device_name': deviceName,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['status'] == 'approved' && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Початок авторизації через Google
  static Future<Map<String, dynamic>> googleStart() async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({'action': 'google_start'}),
      ).timeout(const Duration(seconds: 10));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Перевірка статусу авторизації через Google
  static Future<Map<String, dynamic>> googleCheck(String ticketToken) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'action': 'google_check',
          'token': ticketToken,
          'device_name': deviceName,
        }),
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['status'] == 'approved' && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Реєстрація нового користувача
  static Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required String confirmPassword,
  }) async {
    final uri = Uri.parse('$baseUrl/api/app_auth.php');
    try {
      final res = await http.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'action': 'register',
          'username': username,
          'email': email,
          'password': password,
          'confirm_password': confirmPassword,
          'device_name': deviceName,
        }),
      ).timeout(const Duration(seconds: 12));

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true && data['token'] != null) {
        await saveToken(data['token'].toString());
      }
      return data;
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Оновлення профілю
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

  /// Інформація про оплату / підписку
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

  /// Завантаження треку в локальну папку (для експорту або збереження)
  static Future<String?> downloadTrack(TrackModel track, {Function(double)? onProgress}) async {
    final t = _token ?? '';
    final url = '$baseUrl/api/app_download.php?track_id=${track.id}&id=${track.id}&token=$t';

    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll({
        'User-Agent': 'TryzubPlayer-Multiplatform/$appVersion',
        'X-App-Version': appVersion,
        if (_token != null) 'X-App-Token': _token!,
      });

      final response = await http.Client().send(req);
      if (response.statusCode != 200) return null;

      final total = response.contentLength ?? 0;
      int received = 0;

      Directory? baseDir;
      try {
        if (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
          baseDir = await getDownloadsDirectory();
        }
      } catch (_) {}
      baseDir ??= await getApplicationDocumentsDirectory();

      final targetDir = (!kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS))
          ? baseDir
          : Directory('${baseDir.path}/Tryzub_Music');
      if (!targetDir.existsSync()) {
        targetDir.createSync(recursive: true);
      }

      final safeTitle = track.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final fileName = safeTitle.isNotEmpty
          ? 'Тризуб МС - $safeTitle.mp3'
          : (track.fileName.isNotEmpty ? track.fileName : 'track_${track.id}.mp3');
      final file = File('${targetDir.path}/$fileName');
      final sink = file.openWrite();

      await response.stream.listen((chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      }).asFuture();

      await sink.flush();
      await sink.close();
      await fetchProfile();
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Перевірка оновлень застосунку (як у старих застосунках)
  static Future<AppVersionInfo?> checkAppVersion() async {
    String os = 'ios';
    if (!kIsWeb) {
      if (Platform.isAndroid) os = 'android';
      if (Platform.isWindows) os = 'windows';
      if (Platform.isMacOS) os = 'macos';
      if (Platform.isLinux) os = 'linux';
    }
    final uri = Uri.parse('$baseUrl/api/app_version.php?os=$os');
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          final srvVer = data['current_version']?.toString() ?? '2.4';
          final minVer = data['min_version']?.toString() ?? '2.0';
          final dlUrl = data['download_url']?.toString() ?? 'https://tryzubmc-official.top';
          final changes = (data['changelog'] as List?)?.map((e) => e.toString()).toList() ?? [];

          final hasUpdate = _isVersionGreater(srvVer, appVersion);
          final isMandatory = _isVersionGreater(minVer, appVersion);

          return AppVersionInfo(
            hasUpdate: hasUpdate,
            isMandatory: isMandatory,
            currentVersion: appVersion,
            serverVersion: srvVer,
            downloadUrl: dlUrl,
            changelog: changes,
          );
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isVersionGreater(String v1, String v2) {
    try {
      final p1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final p2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      for (int i = 0; i < 3; i++) {
        final a = i < p1.length ? p1[i] : 0;
        final b = i < p2.length ? p2[i] : 0;
        if (a > b) return true;
        if (a < b) return false;
      }
    } catch (_) {}
    return false;
  }
}

class AppVersionInfo {
  final bool hasUpdate;
  final bool isMandatory;
  final String currentVersion;
  final String serverVersion;
  final String downloadUrl;
  final List<String> changelog;

  AppVersionInfo({
    required this.hasUpdate,
    required this.isMandatory,
    required this.currentVersion,
    required this.serverVersion,
    required this.downloadUrl,
    required this.changelog,
  });
}

