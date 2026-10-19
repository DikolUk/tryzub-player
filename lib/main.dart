import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiService.initSession();
  runApp(const TryzubApp());
}

class TryzubApp extends StatelessWidget {
  const TryzubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Тризуб МС — Офіційний Плеєр',
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
  bool _isLoading = true;
  String _searchQuery = '';

  int _selectedNavIndex = 0; // 0 = Усі треки, 1 = Топ-треки, 2 = Профіль / Підписка

  // Стан аудіоплеєра
  TrackModel? _currentTrack;
  PlayerState _playerState = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  bool _isShuffle = false;
  bool _isRepeat = false;

  final Map<int, double> _downloadProgress = {};

  @override
  void initState() {
    super.initState();
    _initAudioListeners();
    _loadTracks();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  void _initAudioListeners() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playerState = state);
    });

    _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });

    _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) setState(() => _duration = dur);
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (_isRepeat) {
        if (_currentTrack != null) _playTrack(_currentTrack!);
      } else {
        _playNext();
      }
    });
  }

  Future<void> _loadTracks() async {
    setState(() => _isLoading = true);
    final list = await ApiService.getTracks();
    if (mounted) {
      setState(() {
        _tracks = list;
        _applyFilter();
        _isLoading = false;
      });
    }
  }

  void _applyFilter() {
    var result = List<TrackModel>.from(_tracks);
    if (_selectedNavIndex == 1) {
      // Топ треків за кількістю прослуховувань
      result.sort((a, b) => b.playCount.compareTo(a.playCount));
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase().trim();
      result = result
          .where((t) =>
              t.title.toLowerCase().contains(q) ||
              t.artist.toLowerCase().contains(q) ||
              t.fileName.toLowerCase().contains(q))
          .toList();
    }
    _filteredTracks = result;
  }

  Future<void> _playTrack(TrackModel track) async {
    final streamUrl = ApiService.getStreamUrl(track.id);
    setState(() {
      _currentTrack = track;
      _position = Duration.zero;
      _duration = Duration.zero;
    });

    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(
        UrlSource(streamUrl),
        volume: _volume,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ApiService.isAuthenticated
                  ? 'Помилка відтворення: $e'
                  : 'Для відтворення повного стріму увійдіть у свій акаунт Тризуб МС!',
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

  Future<void> _downloadTrack(TrackModel track) async {
    if (!ApiService.isAuthenticated) {
      _showAuthModal();
      return;
    }

    setState(() => _downloadProgress[track.id] = 0.01);
    final path = await ApiService.downloadTrack(
      track,
      onProgress: (p) => setState(() => _downloadProgress[track.id] = p),
    );

    setState(() => _downloadProgress.remove(track.id));

    if (mounted) {
      if (path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Трек «${track.title}» завантажено!'),
            action: (!kIsWeb && (Platform.isIOS || Platform.isAndroid))
                ? SnackBarAction(
                    label: 'Поділитися',
                    onPressed: () => Share.shareXFiles([XFile(path)]),
                  )
                : null,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Помилка або вичерпано ліміт завантажень')),
        );
      }
    }
  }

  // ==========================================================================
  // АВТОРИЗАЦІЯ ТА ПРОФІЛЬ
  // ==========================================================================
  void _showAuthModal() {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool isSubmitting = false;
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0D1527),
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
                    if (errorText != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          errorText!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                        ),
                      ),
                    TextField(
                      controller: userCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Логін або Email',
                        prefixIcon: Icon(Icons.person_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: passCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Пароль',
                        prefixIcon: Icon(Icons.lock_rounded),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final uri = Uri.parse('https://t.me/tryzub_login_bot');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                      icon: const Icon(Icons.send_rounded, color: Color(0xFF00BFFF)),
                      label: const Text('Швидкий вхід через Telegram Бот'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Скасувати'),
                ),
                FilledButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          final u = userCtrl.text.trim();
                          final p = passCtrl.text.trim();
                          if (u.isEmpty || p.isEmpty) return;

                          setModalState(() {
                            isSubmitting = true;
                            errorText = null;
                          });

                          final res = await ApiService.login(u, p);
                          if (!ctx.mounted) return;
                          if (res['success'] == true) {
                            Navigator.pop(ctx);
                            if (mounted) {
                              setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Вхід виконано успішно!')),
                              );
                            }
                          } else {
                            setModalState(() {
                              isSubmitting = false;
                              errorText = res['error']?.toString() ?? 'Невірний логін чи пароль';
                            });
                          }
                        },
                  child: isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Увійти'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ==========================================================================
  // ІНТЕРФЕЙС КОРИСТУВАЧА (DESKTOP + MOBILE)
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isDesktop = width >= 800;

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
                errorBuilder: (_, __, ___) => const Icon(Icons.military_tech_rounded, color: Color(0xFF00BFFF)),
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
                  'Офіційний кросплатформний плеєр',
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
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music_rounded, color: Color(0xFF00BFFF)),
                  label: Text('Всі треки'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.local_fire_department_outlined),
                  selectedIcon: Icon(Icons.local_fire_department_rounded, color: Color(0xFFFFD700)),
                  label: Text('Популярні'),
                ),
                NavigationRailDestination(
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
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music_rounded, color: Color(0xFF00BFFF)),
                  label: 'Всі треки',
                ),
                NavigationDestination(
                  icon: Icon(Icons.local_fire_department_outlined),
                  selectedIcon: Icon(Icons.local_fire_department_rounded, color: Color(0xFFFFD700)),
                  label: 'Популярні',
                ),
                NavigationDestination(
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
    return Column(
      children: [
        // Пошук
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Пошук серед ${_tracks.length} треків Тризуб МС...',
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
              fillColor: const Color(0xFF0E1626),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onChanged: (val) {
              setState(() {
                _searchQuery = val;
                _applyFilter();
              });
            },
          ),
        ),

        // Список пісень
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _filteredTracks.isEmpty
                  ? const Center(child: Text('Нічого не знайдено.'))
                  : ListView.builder(
                      itemCount: _filteredTracks.length,
                      itemBuilder: (ctx, idx) {
                        final track = _filteredTracks[idx];
                        final isPlayingThis =
                            _currentTrack?.id == track.id && _playerState == PlayerState.playing;
                        final isSelected = _currentTrack?.id == track.id;
                        final isDownloading = _downloadProgress.containsKey(track.id);

                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF1E293B).withValues(alpha: 0.6)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            border: isSelected
                                ? Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.4))
                                : null,
                          ),
                          child: ListTile(
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Image.network(
                                    track.coverUrl,
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 48,
                                      height: 48,
                                      color: const Color(0xFF1E293B),
                                      child: const Icon(Icons.music_note_rounded),
                                    ),
                                  ),
                                  if (isPlayingThis)
                                    Container(
                                      width: 48,
                                      height: 48,
                                      color: Colors.black.withValues(alpha: 0.4),
                                      child: const Icon(
                                        Icons.equalizer_rounded,
                                        color: Color(0xFF00BFFF),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            title: Text(
                              track.title,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isSelected ? const Color(0xFF00BFFF) : Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Row(
                              children: [
                                Text(
                                  track.artist,
                                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  '▶ ${track.playCount}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '⬇ ${track.downloadCount}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                                ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Завантажити MP3',
                                  icon: isDownloading
                                      ? SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            value: _downloadProgress[track.id],
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.download_rounded),
                                  onPressed: isDownloading ? null : () => _downloadTrack(track),
                                ),
                                IconButton(
                                  icon: Icon(
                                    isPlayingThis
                                        ? Icons.pause_circle_filled_rounded
                                        : Icons.play_circle_fill_rounded,
                                    color: const Color(0xFF00BFFF),
                                    size: 32,
                                  ),
                                  onPressed: () {
                                    if (isSelected && isPlayingThis) {
                                      _audioPlayer.pause();
                                    } else {
                                      _playTrack(track);
                                    }
                                  },
                                ),
                              ],
                            ),
                            onTap: () => _playTrack(track),
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
          // Смуга прогресу
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

          // Кнопки керування
          Row(
            children: [
              // Обкладинка і назва
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
                    Text(
                      _currentTrack!.artist,
                      style: const TextStyle(fontSize: 11, color: Colors.white60),
                    ),
                  ],
                ),
              ),

              // Кнопки відтворення
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
                  _volume == 0 ? Icons.volume_off_rounded : (_volume < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded),
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
  // ВКЛАДКА 3: ПРОФІЛЬ / ПІДПИСКА / ПІДТРИМКА
  // ==========================================================================
  Widget _buildProfileTab() {
    final user = ApiService.currentUser;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                        Text(
                          user?.email.isNotEmpty == true ? user!.email : 'Вхід дає доступ до повного завантаження та стрімінгу',
                          style: const TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: (user?.isUnlimited == true)
                                ? Colors.amber.withValues(alpha: 0.2)
                                : const Color(0xFF00BFFF).withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            user?.isUnlimited == true
                                ? 'Тариф: VIP Безліміт'
                                : 'Тариф: Базовий (Залишилось завантажень: ${user?.remainingDownloads ?? 5}/тиждень)',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: user?.isUnlimited == true ? Colors.amber : const Color(0xFF00BFFF),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (ApiService.isAuthenticated)
                    IconButton(
                      tooltip: 'Вийти з акаунта',
                      icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                      onPressed: () async {
                        await ApiService.logout();
                        setState(() {});
                      },
                    )
                  else
                    FilledButton(
                      onPressed: _showAuthModal,
                      child: const Text('Увійти'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Підтримка / Банка Monobank
          Card(
            color: const Color(0xFF0F172A),
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.volunteer_activism_rounded, color: Color(0xFFFFD700)),
                      SizedBox(width: 10),
                      Text(
                        'Підтримати творчість Тризуб МС',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Тризуб МС — ветеран ЗСУ, комісований після важких боїв. Всі кошти йдуть на підтримку автора, створення нових патріотичних треків та допомогу побратимам на фронті.',
                    style: TextStyle(fontSize: 13, height: 1.4, color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE11D48)),
                        onPressed: () async {
                          final uri = Uri.parse('https://send.monobank.ua/jar/6wTtSWxYL2');
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          }
                        },
                        icon: const Icon(Icons.favorite_rounded),
                        label: const Text('Банка Monobank'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final uri = Uri.parse('https://tryzubmc-official.top/');
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          }
                        },
                        icon: const Icon(Icons.language_rounded),
                        label: const Text('Офіційний сайт'),
                      ),
                    ],
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
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
