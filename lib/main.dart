import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_service.dart';
import 'offline_manager.dart';

// ============================================================================
// СЕРВІС КЕРУВАННЯ ЗБЛОКОВАНИМ ЕКРАНОМ (NOW PLAYING / LOCK SCREEN CONTROLS)
// ============================================================================
class NowPlayingService {
  static const _channel = MethodChannel('com.tryzubmc.player/nowplaying');

  static void init({
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onToggle,
    required VoidCallback onNext,
    required VoidCallback onPrev,
    required Function(double) onSeek,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRemotePlay':
          onPlay();
          break;
        case 'onRemotePause':
          onPause();
          break;
        case 'onRemoteToggle':
          onToggle();
          break;
        case 'onRemoteNext':
          onNext();
          break;
        case 'onRemotePrev':
          onPrev();
          break;
        case 'onRemoteSeek':
          final seconds = call.arguments as num? ?? 0;
          onSeek(seconds.toDouble());
          break;
      }
    });
  }

  static void update({
    required String title,
    required String artist,
    required Duration duration,
    required Duration position,
    required bool isPlaying,
  }) {
    try {
      _channel.invokeMethod('updateNowPlaying', {
        'title': title,
        'artist': artist,
        'duration': duration.inSeconds.toDouble(),
        'position': position.inSeconds.toDouble(),
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }

  static void clear() {
    try {
      _channel.invokeMethod('clearNowPlaying');
    } catch (_) {}
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Налаштування безперервного фонового аудіо на iOS та Android
  try {
    await AudioPlayer.global.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {
            AVAudioSessionOptions.defaultToSpeaker,
            AVAudioSessionOptions.allowAirPlay,
            AVAudioSessionOptions.allowBluetooth,
          },
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ),
      ),
    );
  } catch (_) {}

  await ApiService.initSession();
  await OfflineManager.instance.init();
  runApp(const TryzubApp());
}

class TryzubApp extends StatelessWidget {
  const TryzubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Тризуб МС — Офіційний Застосунок',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF060912),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00BFFF),
          secondary: Color(0xFFFFD700),
          surface: Color(0xFF0B101E),
          surfaceContainer: Color(0xFF10172A),
          surfaceContainerHigh: Color(0xFF162038),
          onPrimary: Colors.black,
          onSurface: Colors.white,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: const Color(0xFF16243A),
          contentTextStyle: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          actionTextColor: const Color(0xFFFFD700),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF00BFFF), width: 1.2),
          ),
        ),
        fontFamily: 'Roboto',
      ),
      home: const MainPlayerScreen(),
    );
  }
}

class MainPlayerScreen extends StatefulWidget {
  const MainPlayerScreen({super.key});

  @override
  State<MainPlayerScreen> createState() => _MainPlayerScreenState();
}

class _MainPlayerScreenState extends State<MainPlayerScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();

  List<TrackModel> _tracks = [];
  List<TrackModel> _filteredTracks = [];
  bool _isLoadingTracks = true;
  String _searchQuery = '';

  int _selectedNavIndex = 0; // 0 = Усі треки, 1 = Офлайн, 2 = Профіль

  TrackModel? _currentTrack;
  PlayerState _playerState = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  bool _isShuffle = false;
  bool _isRepeat = false;

  bool _isTransitioning = false; // Захист від повторного виклику перемикання треку

  final Map<int, double> _offlineCacheProgress = {};
  final Map<int, double> _fileDownloadProgress = {};

  @override
  void initState() {
    super.initState();
    _initAudioListeners();
    _initLockScreenControls();
    _loadTracks();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates(manual: false);
    });
  }

  void _initLockScreenControls() {
    NowPlayingService.init(
      onPlay: () {
        if (_playerState != PlayerState.playing) _togglePlayPause();
      },
      onPause: () {
        if (_playerState == PlayerState.playing) _togglePlayPause();
      },
      onToggle: _togglePlayPause,
      onNext: _playNext,
      onPrev: _playPrev,
      onSeek: (seconds) {
        _audioPlayer.seek(Duration(seconds: seconds.toInt()));
      },
    );
  }

  void _initAudioListeners() {
    _audioPlayer.setReleaseMode(ReleaseMode.stop);

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _playerState = state);
      _syncLockScreen();

      if (state == PlayerState.completed) {
        _onTrackFinished();
      }
    });

    _audioPlayer.onDurationChanged.listen((dur) {
      if (!mounted) return;
      setState(() => _duration = dur);
      _syncLockScreen();
    });

    _audioPlayer.onPositionChanged.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
    });

    // Надійна підписка на завершення треку
    _audioPlayer.onPlayerComplete.listen((_) {
      _onTrackFinished();
    });
  }

  void _syncLockScreen() {
    if (_currentTrack != null) {
      NowPlayingService.update(
        title: _currentTrack!.title,
        artist: _currentTrack!.artist,
        duration: _duration,
        position: _position,
        isPlaying: _playerState == PlayerState.playing,
      );
    }
  }

  void _onTrackFinished() {
    if (_isTransitioning) return;
    _isTransitioning = true;

    Future.delayed(const Duration(milliseconds: 400), () {
      _isTransitioning = false;
    });

    if (_isRepeat && _currentTrack != null) {
      _playTrack(_currentTrack!);
    } else {
      _playNext();
    }
  }

  @override
  void dispose() {
    NowPlayingService.clear();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadTracks() async {
    setState(() => _isLoadingTracks = true);
    final tracks = await ApiService.getTracks();
    if (mounted) {
      setState(() {
        _tracks = tracks;
        _isLoadingTracks = false;
        _applyFilter();
      });
    }
  }

  void _applyFilter() {
    List<TrackModel> baseList = _selectedNavIndex == 1
        ? OfflineManager.instance.savedTracks
        : _tracks;

    if (_searchQuery.trim().isEmpty) {
      _filteredTracks = List.from(baseList);
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredTracks = baseList.where((t) {
        return t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q);
      }).toList();
    }
  }

  Future<void> _playTrack(TrackModel track) async {
    setState(() {
      _currentTrack = track;
      _position = Duration.zero;
      _duration = Duration.zero;
    });

    try {
      await _audioPlayer.stop();

      // Якщо трек збережено в офлайн - граємо локальний файл без інтернету!
      if (OfflineManager.instance.isTrackSaved(track.id)) {
        final localPath = OfflineManager.instance.getAudioFilePath(track.id);
        await _audioPlayer.play(
          DeviceFileSource(localPath),
          volume: _volume,
        );
      } else {
        final streamUrl = ApiService.getStreamUrl(track.id);
        await _audioPlayer.play(
          UrlSource(streamUrl),
          volume: _volume,
        );
      }
      _syncLockScreen();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ApiService.isAuthenticated
                  ? 'Помилка відтворення: $e'
                  : 'Для прослуховування стріму увійдіть у свій акаунт Тризуб МС!',
            ),
            action: ApiService.isAuthenticated
                ? null
                : SnackBarAction(
                    label: 'Увійти',
                    onPressed: _showAuthModal,
                  ),
          ),
        );
      }
    }
  }

  Future<void> _togglePlayPause() async {
    if (_currentTrack == null) {
      if (_filteredTracks.isNotEmpty) {
        _playTrack(_filteredTracks.first);
      }
      return;
    }

    if (_playerState == PlayerState.playing) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.resume();
    }
    _syncLockScreen();
  }

  void _playNext() {
    if (_filteredTracks.isEmpty) return;
    if (_currentTrack == null) {
      _playTrack(_filteredTracks.first);
      return;
    }

    if (_isShuffle) {
      final next = (_filteredTracks.toList()..shuffle()).first;
      _playTrack(next);
      return;
    }

    final currentIndex = _filteredTracks.indexWhere((t) => t.id == _currentTrack!.id);
    if (currentIndex >= 0 && currentIndex < _filteredTracks.length - 1) {
      _playTrack(_filteredTracks[currentIndex + 1]);
    } else {
      _playTrack(_filteredTracks.first);
    }
  }

  void _playPrev() {
    if (_filteredTracks.isEmpty) return;
    if (_currentTrack == null) {
      _playTrack(_filteredTracks.first);
      return;
    }

    final currentIndex = _filteredTracks.indexWhere((t) => t.id == _currentTrack!.id);
    if (currentIndex > 0) {
      _playTrack(_filteredTracks[currentIndex - 1]);
    } else {
      _playTrack(_filteredTracks.last);
    }
  }

  void _showNotification(
    String text, {
    IconData icon = Icons.check_circle_rounded,
    Color iconColor = const Color(0xFF22C55E),
  }) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF16243A),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: iconColor.withValues(alpha: 0.8), width: 1.5),
        ),
        content: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        messenger.hideCurrentSnackBar();
      }
    });
  }

  // ==========================================================================
  // БЛИСКАВКА ⚡ — ЗБЕРЕГТИ В ОФЛАЙН (КЕШ ДЛЯ ПРОСЛУХОВУВАННЯ БЕЗ ІНТЕРНЕТУ)
  // ==========================================================================
  Future<void> _toggleSaveOffline(TrackModel track) async {
    final isSaved = OfflineManager.instance.isTrackSaved(track.id);
    if (isSaved) {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF0F172A),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.share_rounded, color: Color(0xFF00BFFF)),
                title: const Text('Поділитися аудіофайлом'),
                onTap: () {
                  Navigator.pop(ctx);
                  final path = OfflineManager.instance.getAudioFilePath(track.id);
                  Share.shareXFiles([XFile(path)], text: 'Тризуб МС — ${track.title}');
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                title: const Text('Видалити з офлайн-памʼяті'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await OfflineManager.instance.deleteTrackOffline(track.id);
                  if (mounted) {
                    setState(() => _applyFilter());
                    _showNotification(
                      'Трек «${track.title}» видалено з офлайну',
                      icon: Icons.delete_outline_rounded,
                      iconColor: Colors.orangeAccent,
                    );
                  }
                },
              ),
            ],
          ),
        ),
      );
      return;
    }

    setState(() => _offlineCacheProgress[track.id] = 0.01);
    final ok = await OfflineManager.instance.saveTrackOffline(
      track,
      onProgress: (p) {
        if (mounted) setState(() => _offlineCacheProgress[track.id] = p);
      },
    );

    if (mounted) {
      setState(() {
        _offlineCacheProgress.remove(track.id);
        _applyFilter();
      });

      if (ok) {
        _showNotification(
          '⚡ «${track.title}» додано в офлайн!',
          icon: Icons.bolt_rounded,
          iconColor: const Color(0xFFFFD700),
        );
      } else {
        if (!ApiService.isAuthenticated) {
          _showAuthModal();
        } else {
          _showNotification(
            'Помилка збереження в офлайн',
            icon: Icons.error_outline_rounded,
            iconColor: Colors.redAccent,
          );
        }
      }
    }
  }

  // ==========================================================================
  // СКАЧУВАННЯ MP3 ФАЙЛУ НА ПРИСТРІЙ (З ПЕРЕВІРКОЮ ТАРИФУ БЕЗЛІМ)
  // ==========================================================================
  Future<void> _downloadTrackFile(TrackModel track) async {
    if (!ApiService.isAuthenticated) {
      _showAuthModal();
      return;
    }

    final user = ApiService.currentUser;
    if (user != null && !user.isUnlimited && user.remainingDownloads <= 0) {
      _showUnlimitedUpgradeDialog();
      return;
    }

    setState(() => _fileDownloadProgress[track.id] = 0.01);
    final path = await ApiService.downloadTrack(
      track,
      onProgress: (p) {
        if (mounted) setState(() => _fileDownloadProgress[track.id] = p);
      },
    );

    if (mounted) {
      setState(() => _fileDownloadProgress.remove(track.id));
      if (path != null) {
        _showNotification(
          'Трек «${track.title}» успішно завантажено!',
          icon: Icons.download_done_rounded,
          iconColor: const Color(0xFF00BFFF),
        );
      } else {
        _showNotification(
          'Не вдалося завантажити трек',
          icon: Icons.error_outline_rounded,
          iconColor: Colors.redAccent,
        );
      }
    }
  }

  // ==========================================================================
  // МОДАЛЬНЕ ВІКНО «КУПИТИ БЕЗЛІМ» (ЯК НА САЙТІ ТА В ANDROID/WINDOWS)
  // ==========================================================================
  void _showUnlimitedUpgradeDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101726),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFFFD700), width: 1.5),
        ),
        title: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('👑 ТАРИФ БЕЗЛІМ', style: TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.bold, fontSize: 20)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('200 грн · назавжди', style: TextStyle(color: Color(0xFF22C55E), fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF182236),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('✓ Необмежене завантаження всіх треків', style: TextStyle(color: Colors.white, fontSize: 13)),
                    SizedBox(height: 6),
                    Text('✓ Зняття щотижневого ліміту 5 треків', style: TextStyle(color: Colors.white, fontSize: 13)),
                    SizedBox(height: 6),
                    Text('✓ Повна дискографія «Тризуб МС» в 1 клік', style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('Реквізити для оплати (прямий переказ):', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),

              // Номер картки
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B101E),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '4323 3473 6111 7044',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: Color(0xFFFFD700)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded, color: Color(0xFF00BFFF), size: 20),
                      tooltip: 'Скопіювати номер картки',
                      onPressed: () {
                        Clipboard.setData(const ClipboardData(text: '4323347361117044'));
                        _showNotification('Номер картки 4323 3473 6111 7044 скопійовано!');
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF00BFFF),
                  side: const BorderSide(color: Color(0xFF00BFFF)),
                  minimumSize: const Size.fromHeight(42),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('Підтвердити в Telegram (@tryzub_mc_bot)'),
                onPressed: () async {
                  final uri = Uri.parse('https://t.me/tryzub_mc_bot');
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрити')),
        ],
      ),
    );
  }

  // ==========================================================================
  // СИСТЕМА ОНОВЛЕНЬ ЗАСТОСУНКУ (ЯК У СТАРИХ ДОДАТКАХ)
  // ==========================================================================
  Future<void> _checkForUpdates({required bool manual}) async {
    final info = await ApiService.checkAppVersion();
    if (!mounted) return;

    if (info != null && info.hasUpdate) {
      showDialog(
        context: context,
        barrierDismissible: !info.isMandatory,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF10172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFF00BFFF), width: 1.5),
          ),
          title: Row(
            children: [
              const Icon(Icons.system_update_rounded, color: Color(0xFF00BFFF)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Оновлення v${info.serverVersion}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Доступна нова версія ${info.serverVersion}! (Ваша версія: ${info.currentVersion})',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                if (info.changelog.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Що нового:', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFFFD700), fontSize: 13)),
                  const SizedBox(height: 6),
                  ...info.changelog.map((c) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text('• $c', style: const TextStyle(fontSize: 12, color: Colors.white60)),
                      )),
                ],
              ],
            ),
          ),
          actions: [
            if (!info.isMandatory)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Пізніше', style: TextStyle(color: Colors.white60)),
              ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BFFF),
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                final uri = Uri.parse(info.downloadUrl);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: const Text('Оновити зараз', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    } else if (manual) {
      _showNotification('У вас встановлено найновішу версію застосунку (v2.4)!');
    }
  }

  // ==========================================================================
  // МОДАЛЬНЕ ВІКНО АВТОРИЗАЦІЇ
  // ==========================================================================
  void _showAuthModal() {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return _AuthDialogContent(
          userCtrl: userCtrl,
          passCtrl: passCtrl,
          onSuccess: () {
            if (mounted) {
              setState(() {});
              _showNotification('Вхід виконано успішно!');
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 700;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B101E),
        elevation: 0,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/logo.png',
                width: 34,
                height: 34,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.military_tech_rounded, color: Color(0xFF00BFFF)),
              ),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ТРИЗУБ МС',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                    fontSize: 16,
                  ),
                ),
                Text(
                  'Офіційний застосунок',
                  style: TextStyle(fontSize: 11, color: Color(0xFFFFD700)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (ApiService.isAuthenticated)
            Chip(
              avatar: const Icon(Icons.verified_user_rounded, color: Colors.greenAccent, size: 16),
              label: Text(
                ApiService.currentUser?.username ?? 'Користувач',
                style: const TextStyle(fontSize: 12),
              ),
            )
          else
            FilledButton.tonalIcon(
              onPressed: _showAuthModal,
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('Увійти'),
            ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Оновити треки',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadTracks,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          if (isDesktop)
            NavigationRail(
              backgroundColor: const Color(0xFF0B101E),
              selectedIndex: _selectedNavIndex,
              onDestinationSelected: (idx) {
                setState(() {
                  _selectedNavIndex = idx;
                  _applyFilter();
                });
              },
              labelType: NavigationRailLabelType.all,
              destinations: [
                const NavigationRailDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music_rounded, color: Color(0xFF00BFFF)),
                  label: Text('Всі треки'),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    label: Text('${OfflineManager.instance.savedTracks.length}'),
                    isLabelVisible: OfflineManager.instance.savedTracks.isNotEmpty,
                    child: const Icon(Icons.bolt_outlined),
                  ),
                  selectedIcon: const Icon(Icons.bolt_rounded, color: Color(0xFFFFD700)),
                  label: const Text('Офлайн'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.account_circle_outlined),
                  selectedIcon: Icon(Icons.account_circle_rounded, color: Color(0xFF00BFFF)),
                  label: Text('Профіль'),
                ),
              ],
            ),
          if (isDesktop) const VerticalDivider(width: 1, color: Color(0xFF1E293B)),
          Expanded(
            child: _selectedNavIndex == 2
                ? _buildProfileTab()
                : _buildTrackListView(),
          ),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPlayerBottomBar(),
          if (!isDesktop)
            NavigationBar(
              backgroundColor: const Color(0xFF0B101E),
              selectedIndex: _selectedNavIndex,
              onDestinationSelected: (idx) {
                setState(() {
                  _selectedNavIndex = idx;
                  _applyFilter();
                });
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music_rounded, color: Color(0xFF00BFFF)),
                  label: 'Всі треки',
                ),
                NavigationDestination(
                  icon: Badge(
                    label: Text('${OfflineManager.instance.savedTracks.length}'),
                    isLabelVisible: OfflineManager.instance.savedTracks.isNotEmpty,
                    child: const Icon(Icons.bolt_outlined),
                  ),
                  selectedIcon: const Icon(Icons.bolt_rounded, color: Color(0xFFFFD700)),
                  label: 'Офлайн',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.account_circle_outlined),
                  selectedIcon: Icon(Icons.account_circle_rounded, color: Color(0xFF00BFFF)),
                  label: 'Профіль',
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTrackListView() {
    final isOfflineTab = _selectedNavIndex == 1;

    return Column(
      children: [
        if (isOfflineTab)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF0F172A),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded, size: 20, color: Color(0xFFFFD700)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Офлайн треків: ${OfflineManager.instance.savedTracks.length} (${OfflineManager.instance.getTotalSizeFormatted()})',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),

        // Пошук
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: InputDecoration(
              hintText: isOfflineTab
                  ? 'Пошук в офлайн треках...'
                  : 'Пошук серед ${_tracks.length} треків Тризуб МС...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        setState(() {
                          _searchQuery = '';
                          _applyFilter();
                        });
                      },
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF0F172A),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1E293B)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1E293B)),
              ),
            ),
            onChanged: (val) {
              setState(() {
                _searchQuery = val;
                _applyFilter();
              });
            },
          ),
        ),

        // Список треків
        Expanded(
          child: _isLoadingTracks
              ? const Center(child: CircularProgressIndicator())
              : _filteredTracks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              isOfflineTab ? Icons.bolt_rounded : Icons.music_off_rounded,
                              size: 64,
                              color: Colors.white24,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              isOfflineTab
                                  ? 'У вас ще немає збережених треків.\nНатисніть блискавку ⚡ біля будь-якого треку, щоб слухати його офлайн!'
                                  : 'Треків не знайдено',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white60, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filteredTracks.length,
                      itemBuilder: (context, index) {
                        final track = _filteredTracks[index];
                        final isSelected = _currentTrack?.id == track.id;
                        final isPlaying = isSelected && _playerState == PlayerState.playing;
                        final isSavedOffline = OfflineManager.instance.isTrackSaved(track.id);
                        final offlineP = _offlineCacheProgress[track.id];
                        final fileP = _fileDownloadProgress[track.id];

                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF00BFFF).withValues(alpha: 0.12)
                                : const Color(0xFF0B101E),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF00BFFF).withValues(alpha: 0.5)
                                  : Colors.transparent,
                            ),
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                            leading: Stack(
                              alignment: Alignment.center,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    track.coverUrl,
                                    width: 46,
                                    height: 46,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 46,
                                      height: 46,
                                      color: const Color(0xFF1E293B),
                                      child: const Icon(Icons.music_note_rounded, color: Colors.white54),
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Container(
                                    width: 46,
                                    height: 46,
                                    decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Icon(
                                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                      color: const Color(0xFF00BFFF),
                                    ),
                                  ),
                              ],
                            ),
                            // 2 рядки для назви пісні, щоб довга назва ніколи не обрізалась!
                            title: Text(
                              track.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                fontSize: 13.5,
                                height: 1.2,
                                color: isSelected ? const Color(0xFF00BFFF) : Colors.white,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  Text(
                                    track.artist,
                                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                                  ),
                                  if (isSavedOffline) ...[
                                    const SizedBox(width: 6),
                                    const Icon(Icons.bolt_rounded, size: 13, color: Color(0xFFFFD700)),
                                    const SizedBox(width: 1),
                                    const Text('Офлайн', style: TextStyle(color: Color(0xFFFFD700), fontSize: 10, fontWeight: FontWeight.bold)),
                                  ],
                                ],
                              ),
                            ),
                            // Компактний блок кнопок: ⚡ Блискавка + ⬇️ Скачати + ▶️ Play
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 1. БЛИСКАВКА ⚡ (Офлайн прослуховування)
                                if (offlineP != null)
                                  Padding(
                                    padding: const EdgeInsets.all(4.0),
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        value: offlineP > 0 ? offlineP : null,
                                        strokeWidth: 2.2,
                                        color: const Color(0xFFFFD700),
                                      ),
                                    ),
                                  )
                                else
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                    visualDensity: VisualDensity.compact,
                                    tooltip: isSavedOffline ? 'Збережено в офлайн (блискавка ⚡)' : 'Додати в офлайн (блискавка ⚡)',
                                    icon: Icon(
                                      isSavedOffline
                                          ? Icons.bolt_rounded
                                          : Icons.bolt_outlined,
                                      color: isSavedOffline
                                          ? const Color(0xFFFFD700)
                                          : Colors.white38,
                                      size: 23,
                                    ),
                                    onPressed: () => _toggleSaveOffline(track),
                                  ),

                                // 2. ЗАВАНТАЖИТИ ⬇️
                                if (fileP != null)
                                  Padding(
                                    padding: const EdgeInsets.all(4.0),
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        value: fileP > 0 ? fileP : null,
                                        strokeWidth: 2.0,
                                        color: const Color(0xFF00BFFF),
                                      ),
                                    ),
                                  )
                                else
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                    visualDensity: VisualDensity.compact,
                                    tooltip: 'Завантажити',
                                    icon: const Icon(
                                      Icons.download_rounded,
                                      color: Color(0xFF00BFFF),
                                      size: 21,
                                    ),
                                    onPressed: () => _downloadTrackFile(track),
                                  ),

                                const SizedBox(width: 2),

                                // 3. PLAY / PAUSE КНОПКА ▶️
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    isSelected && isPlaying
                                        ? Icons.pause_circle_filled_rounded
                                        : Icons.play_circle_fill_rounded,
                                    color: isSelected
                                        ? const Color(0xFF00BFFF)
                                        : const Color(0xFFFFD700),
                                    size: 30,
                                  ),
                                  onPressed: () {
                                    if (isSelected) {
                                      _togglePlayPause();
                                    } else {
                                      _playTrack(track);
                                    }
                                  },
                                ),
                              ],
                            ),
                            onTap: () {
                              if (isSelected) {
                                _togglePlayPause();
                              } else {
                                _playTrack(track);
                              }
                            },
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  // ==========================================================================
  // НИЖНЯ ПАНЕЛЬ АУДІОПЛЕЄРА
  // ==========================================================================
  Widget _buildPlayerBottomBar() {
    if (_currentTrack == null) return const SizedBox.shrink();

    final isPlaying = _playerState == PlayerState.playing;
    final totalSec = _duration.inSeconds;
    final currentSec = _position.inSeconds.clamp(0, totalSec > 0 ? totalSec : 0);
    final isOffline = OfflineManager.instance.isTrackSaved(_currentTrack!.id);

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        border: Border(
          top: BorderSide(color: Color(0xFF1E293B), width: 1.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                _formatDuration(_position),
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    activeTrackColor: const Color(0xFF00BFFF),
                    inactiveTrackColor: Colors.white12,
                    thumbColor: const Color(0xFFFFD700),
                  ),
                  child: Slider(
                    value: currentSec.toDouble(),
                    max: totalSec > 0 ? totalSec.toDouble() : 1.0,
                    onChanged: (val) {
                      _audioPlayer.seek(Duration(seconds: val.toInt()));
                    },
                  ),
                ),
              ),
              Text(
                _formatDuration(_duration),
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
          ),

          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  _currentTrack!.coverUrl,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 44,
                    height: 44,
                    color: const Color(0xFF1E293B),
                    child: const Icon(Icons.music_note_rounded, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentTrack!.title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        Text(
                          _currentTrack!.artist,
                          style: const TextStyle(fontSize: 11, color: Colors.white60),
                        ),
                        if (isOffline) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.bolt_rounded, size: 13, color: Color(0xFFFFD700)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              IconButton(
                icon: Icon(
                  Icons.shuffle_rounded,
                  size: 20,
                  color: _isShuffle ? const Color(0xFFFFD700) : Colors.white38,
                ),
                onPressed: () => setState(() => _isShuffle = !_isShuffle),
              ),
              IconButton(
                icon: const Icon(Icons.skip_previous_rounded),
                onPressed: _playPrev,
              ),
              IconButton(
                icon: Icon(
                  isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                  size: 38,
                  color: const Color(0xFF00BFFF),
                ),
                onPressed: _togglePlayPause,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded),
                onPressed: _playNext,
              ),
              IconButton(
                icon: Icon(
                  Icons.repeat_rounded,
                  size: 20,
                  color: _isRepeat ? const Color(0xFFFFD700) : Colors.white38,
                ),
                onPressed: () => setState(() => _isRepeat = !_isRepeat),
              ),
              if (MediaQuery.of(context).size.width > 680) ...[
                const SizedBox(width: 8),
                Icon(
                  _volume == 0
                      ? Icons.volume_off_rounded
                      : (_volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
                  size: 18,
                  color: Colors.white60,
                ),
                SizedBox(
                  width: 80,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                      activeTrackColor: const Color(0xFF00BFFF),
                      inactiveTrackColor: Colors.white12,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: _volume,
                      min: 0.0,
                      max: 1.0,
                      onChanged: (val) {
                        setState(() => _volume = val);
                        _audioPlayer.setVolume(val);
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // ВКЛАДКА 3: ПРОФІЛЬ / ТАРИФ БЕЗЛІМ / ПІДТРИМКА КАРТКОЮ / ОНОВЛЕННЯ
  // ==========================================================================
  Widget _buildProfileTab() {
    final user = ApiService.currentUser;
    final isUnlimited = user?.isUnlimited ?? false;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Інформація користувача
          Card(
            color: const Color(0xFF0F172A),
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: const Color(0xFF00BFFF).withValues(alpha: 0.2),
                    child: const Icon(Icons.person_rounded, size: 36, color: Color(0xFF00BFFF)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.username ?? 'Гість (Без авторизації)',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isUnlimited ? const Color(0xFF22C55E).withValues(alpha: 0.2) : const Color(0xFFFFD700).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                isUnlimited ? '👑 ТАРИФ БЕЗЛІМ' : 'Тариф: FREE (5 треків/тижд)',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: isUnlimited ? const Color(0xFF22C55E) : const Color(0xFFFFD700),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (user != null && !isUnlimited) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Залишилось завантажень: ${user.remainingDownloads}',
                            style: const TextStyle(fontSize: 11, color: Colors.white54),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (ApiService.isAuthenticated)
                    IconButton(
                      icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                      tooltip: 'Вийти з акаунта',
                      onPressed: () async {
                        await ApiService.logout();
                        setState(() {});
                      },
                    )
                  else
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00BFFF),
                        foregroundColor: Colors.black,
                      ),
                      onPressed: _showAuthModal,
                      child: const Text('Увійти'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. БЛОК «КУПИТИ БЕЗЛІМ» (якщо не безлім)
          if (!isUnlimited)
            Card(
              color: const Color(0xFF162038),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: Color(0xFFFFD700), width: 1.2),
              ),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Text('👑', style: TextStyle(fontSize: 24)),
                        SizedBox(width: 8),
                        Text(
                          'ТАРИФ БЕЗЛІМ — 200 грн назавжди',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFFFFD700)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Зніміть будь-які обмеження! Качайте всю дискографію без лімітів 5 треків на тиждень.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD700),
                        foregroundColor: Colors.black,
                        minimumSize: const Size.fromHeight(42),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _showUnlimitedUpgradeDialog,
                      child: const Text('👑 Отримати БЕЗЛІМ (200 грн)', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),

          // 3. ПІДТРИМКА ПРОЕКТУ КАРТКОЮ 4323 3473 6111 7044
          Card(
            color: const Color(0xFF0F172A),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.credit_card_rounded, color: Color(0xFF00BFFF)),
                      SizedBox(width: 10),
                      Text(
                        'Підтримка проекту «Тризуб МС»',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Підтримайте створення нових українських військово-патріотичних треків прямим переказом на картку:',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 14),

                  // Картка з кнопкою швидкого копіювання
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B101E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '4323 3473 6111 7044',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.5,
                            color: Color(0xFFFFD700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_rounded, color: Color(0xFF00BFFF)),
                          tooltip: 'Скопіювати номер картки',
                          onPressed: () {
                            Clipboard.setData(const ClipboardData(text: '4323347361117044'));
                            _showNotification('Номер картки 4323 3473 6111 7044 скопійовано!');
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00BFFF),
                      side: const BorderSide(color: Color(0xFF00BFFF)),
                      minimumSize: const Size.fromHeight(40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Telegram-бот підтримки (@tryzub_mc_bot)'),
                    onPressed: () async {
                      final uri = Uri.parse('https://t.me/tryzub_mc_bot');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 4. ОНОВЛЕННЯ ЗАСТОСУНКУ
          Card(
            color: const Color(0xFF0F172A),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, color: Colors.white54),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Версія застосунку: 2.4.0', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        Text('Офіційний мультиплатформний реліз', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => _checkForUpdates(manual: true),
                    child: const Text('Оновлення', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ============================================================================
// ДІАЛОГ АВТОРИЗАЦІЇ З ПІДТРИМКОЮ 2FA, TELEGRAM ТА GOOGLE
// ============================================================================
class _AuthDialogContent extends StatefulWidget {
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;
  final VoidCallback onSuccess;

  const _AuthDialogContent({
    required this.userCtrl,
    required this.passCtrl,
    required this.onSuccess,
  });

  @override
  State<_AuthDialogContent> createState() => _AuthDialogContentState();
}

class _AuthDialogContentState extends State<_AuthDialogContent> {
  bool _isWaiting = false;
  String _waitType = '';
  String _waitCode = '';
  int _secondsLeft = 180;
  String _waitIcon = '🛡️';
  String _waitTitle = 'Підтвердження';
  String _waitDesc = '';
  Timer? _countdownTimer;
  Timer? _pollTimer;

  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startWaitScreen({
    required String type,
    required String codeOrToken,
    required int seconds,
    required String icon,
    required String title,
    required String desc,
  }) {
    _waitType = type;
    _waitCode = codeOrToken;
    _secondsLeft = seconds;
    _waitIcon = icon;
    _waitTitle = title;
    _waitDesc = desc;
    _isWaiting = true;
    _errorMessage = null;

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _secondsLeft--;
        if (_secondsLeft <= 0) {
          _cancelWait('Час очікування підтвердження вичерпано');
        }
      });
    });

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (t) async {
      if (!mounted || !_isWaiting || _waitCode.isEmpty) return;

      Map<String, dynamic> res = {};
      if (_waitType == '2fa') {
        res = await ApiService.check2FA(_waitCode);
      } else if (_waitType == 'tg') {
        res = await ApiService.tgCheck(_waitCode);
      } else if (_waitType == 'google') {
        res = await ApiService.googleCheck(_waitCode);
      }

      final status = res['status']?.toString();
      if (status == 'approved') {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        if (mounted) {
          Navigator.of(context).pop();
          widget.onSuccess();
        }
      } else if (status == 'not_linked') {
        final err = res['error']?.toString() ??
            (_waitType == 'tg'
                ? "Цей Telegram не прив'язано до вашого акаунту або швидкий вхід вимкнено"
                : "Цей Google-акаунт не прив'язано до вашого акаунту");
        _cancelWait(err);
      } else if (status == 'rejected') {
        final err = res['error']?.toString() ?? '⛔ Вхід було відхилено';
        _cancelWait(err);
      } else if (status == 'expired') {
        _cancelWait('Час очікування підтвердження вичерпано');
      }
    });

    setState(() {});
  }

  void _cancelWait([String? reason]) {
    _countdownTimer?.cancel();
    _pollTimer?.cancel();
    if (_waitType == '2fa' && _waitCode.isNotEmpty) {
      ApiService.cancel2FA(_waitCode);
    }
    if (mounted) {
      setState(() {
        _isWaiting = false;
        _waitCode = '';
        _isSubmitting = false;
        if (reason != null) _errorMessage = reason;
      });
    }
  }

  Future<void> _submitLogin() async {
    final u = widget.userCtrl.text.trim();
    final p = widget.passCtrl.text;
    if (u.isEmpty || p.isEmpty) {
      setState(() => _errorMessage = 'Введіть логін та пароль');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final res = await ApiService.login(u, p);

    if (res['requires_2fa'] == true) {
      final twofaCode = res['twofa_code']?.toString() ?? '';
      _startWaitScreen(
        type: '2fa',
        codeOrToken: twofaCode,
        seconds: 180,
        icon: '🛡️',
        title: 'Підтвердження у Telegram',
        desc: 'Ми надіслали запит у ваш Telegram-бот.\nНатисніть кнопку «✅ Так, це я» у боті,\nщоб дозволити вхід.',
      );
      return;
    }

    if (res['success'] == true) {
      if (mounted) {
        Navigator.of(context).pop();
        widget.onSuccess();
      }
    } else {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = res['error']?.toString() ?? 'Невірний логін чи пароль';
        });
      }
    }
  }

  Future<void> _startTgLogin() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final res = await ApiService.tgStart();
    if (res['success'] == true) {
      final token = res['token']?.toString() ?? '';
      final botUrl = res['bot_url']?.toString() ?? '';
      final tgAppUrl = res['tg_app_url']?.toString() ?? '';
      final botUser = res['bot_username']?.toString() ?? 'tryzub_login_bot';

      try {
        if (tgAppUrl.isNotEmpty && await canLaunchUrl(Uri.parse(tgAppUrl))) {
          await launchUrl(Uri.parse(tgAppUrl), mode: LaunchMode.externalNonBrowserApplication);
        } else if (botUrl.isNotEmpty) {
          await launchUrl(Uri.parse(botUrl), mode: LaunchMode.externalApplication);
        }
      } catch (_) {}

      _startWaitScreen(
        type: 'tg',
        codeOrToken: token,
        seconds: 300,
        icon: '📱',
        title: 'Вхід через Telegram',
        desc: 'Відкрийте бот @$botUser\nта натисніть кнопку «Підтвердити» у боті,\nщоб дозволити вхід.',
      );
    } else {
      setState(() {
        _isSubmitting = false;
        _errorMessage = res['error']?.toString() ?? 'Не вдалося ініціювати вхід через Telegram';
      });
    }
  }

  Future<void> _startGoogleLogin() async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final res = await ApiService.googleStart();
    if (res['success'] == true) {
      final token = res['token']?.toString() ?? '';
      final authUrl = res['auth_url']?.toString() ?? '';

      if (authUrl.isNotEmpty) {
        try {
          await launchUrl(Uri.parse(authUrl), mode: LaunchMode.externalApplication);
        } catch (_) {}
      }

      _startWaitScreen(
        type: 'google',
        codeOrToken: token,
        seconds: 300,
        icon: '🌐',
        title: 'Вхід через Google',
        desc: 'Ми відкрили вікно авторизації Google у вашому браузері.\nОберіть Google-акаунт для підтвердження входу.',
      );
    } else {
      setState(() {
        _isSubmitting = false;
        _errorMessage = res['error']?.toString() ?? 'Не вдалося відкрити вхід через Google';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isWaiting) {
      return AlertDialog(
        backgroundColor: const Color(0xFF0D1527),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_waitIcon, style: const TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text(
                _waitTitle,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFFFD700)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                _waitDesc,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 16),
              Text(
                'Залишилось часу: $_secondsLeft сек',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF00BFFF)),
              ),
              const SizedBox(height: 16),
              const CircularProgressIndicator(color: Color(0xFF00BFFF), strokeWidth: 3),
              const SizedBox(height: 20),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent),
                  foregroundColor: Colors.redAccent,
                ),
                onPressed: () => _cancelWait('Вхід скасовано користувачем'),
                child: const Text('✕ Скасувати вхід'),
              ),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: const Color(0xFF0D1527),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.shield_rounded, color: Color(0xFF00BFFF)),
          SizedBox(width: 10),
          Text('Авторизація Тризуб МС'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_errorMessage != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                ),
                child: Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            TextField(
              controller: widget.userCtrl,
              decoration: const InputDecoration(
                labelText: 'Логін або Email',
                prefixIcon: Icon(Icons.person_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: widget.passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Пароль',
                prefixIcon: Icon(Icons.lock_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFD700),
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isSubmitting ? null : _submitLogin,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('⚡ Увійти в акаунт', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(child: Divider(color: Colors.white24)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'або швидкий вхід',
                    style: TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(child: Divider(color: Colors.white24)),
              ],
            ),
            const SizedBox(height: 14),

            // Кнопка Telegram
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0088CC),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(42),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text('Вхід через Telegram-бот', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _isSubmitting ? null : _startTgLogin,
            ),
            const SizedBox(height: 10),

            // Кнопка Google
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF1E293B),
                minimumSize: const Size.fromHeight(42),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.g_mobiledata_rounded, size: 24, color: Colors.blue),
              label: const Text('Вхід через Google', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: _isSubmitting ? null : _startGoogleLogin,
            ),
            const SizedBox(height: 12),

            TextButton(
              onPressed: () async {
                final uri = Uri.parse('https://tryzubmc-official.top/register.php');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              child: const Text(
                'Немає акаунта? Зареєструватися на сайті',
                style: TextStyle(color: Color(0xFF00BFFF), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрити'),
        ),
      ],
    );
  }
}
