import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_service.dart';
import 'offline_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  final Map<int, double> _downloadProgress = {};

  @override
  void initState() {
    super.initState();
    _initAudioListeners();
    _loadTracks();
  }

  void _initAudioListeners() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playerState = state);
    });

    _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) setState(() => _duration = dur);
    });

    _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (_isRepeat) {
        if (_currentTrack != null) _playTrack(_currentTrack!);
      } else {
        _playNext();
      }
    });
  }

  @override
  void dispose() {
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

  Future<void> _toggleSaveOffline(TrackModel track) async {
    final isSaved = OfflineManager.instance.isTrackSaved(track.id);
    if (isSaved) {
      // Показуємо вибір: видалити чи поділитися
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
                title: const Text('Видалити з памʼяті пристрою'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await OfflineManager.instance.deleteTrackOffline(track.id);
                  if (mounted) {
                    setState(() => _applyFilter());
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Трек «${track.title}» видалено з офлайну')),
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

    // Зберігаємо трек в офлайн
    setState(() => _downloadProgress[track.id] = 0.01);
    final ok = await OfflineManager.instance.saveTrackOffline(
      track,
      onProgress: (p) {
        if (mounted) setState(() => _downloadProgress[track.id] = p);
      },
    );

    if (mounted) {
      setState(() {
        _downloadProgress.remove(track.id);
        _applyFilter();
      });

      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF102820),
            content: Row(
              children: [
                const Icon(Icons.offline_pin_rounded, color: Colors.greenAccent),
                const SizedBox(width: 8),
                Expanded(child: Text('«${track.title}» збережено для офлайн-прослуховування!')),
              ],
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ApiService.isAuthenticated
                  ? 'Помилка завантаження'
                  : 'Для повного доступу увійдіть у свій акаунт!',
            ),
            action: ApiService.isAuthenticated
                ? null
                : SnackBarAction(label: 'Увійти', onPressed: _showAuthModal),
          ),
        );
      }
    }
  }

  // ==========================================================================
  // МОДАЛЬНЕ ВІКНО АВТОРИЗАЦІЇ (ЛОГІН, 2FA, TELEGRAM, GOOGLE)
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Вхід виконано успішно!')),
              );
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
                    child: const Icon(Icons.offline_pin_outlined),
                  ),
                  selectedIcon: const Icon(Icons.offline_pin_rounded, color: Colors.greenAccent),
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
                    child: const Icon(Icons.offline_pin_outlined),
                  ),
                  selectedIcon: const Icon(Icons.offline_pin_rounded, color: Colors.greenAccent),
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
                const Icon(Icons.cloud_off_rounded, size: 18, color: Colors.greenAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Збережено треків: ${OfflineManager.instance.savedTracks.length} (${OfflineManager.instance.getTotalSizeFormatted()})',
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
                              isOfflineTab ? Icons.download_for_offline_rounded : Icons.music_off_rounded,
                              size: 64,
                              color: Colors.white24,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              isOfflineTab
                                  ? 'У вас ще немає збережених треків.\nНатисніть кнопку ⬇️ біля будь-якого треку, щоб слухати його офлайн!'
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
                        final downloadP = _downloadProgress[track.id];

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
                            leading: Stack(
                              alignment: Alignment.center,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    track.coverUrl,
                                    width: 48,
                                    height: 48,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 48,
                                      height: 48,
                                      color: const Color(0xFF1E293B),
                                      child: const Icon(Icons.music_note_rounded, color: Colors.white54),
                                    ),
                                  ),
                                ),
                                if (isSelected)
                                  Container(
                                    width: 48,
                                    height: 48,
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
                            title: Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                color: isSelected ? const Color(0xFF00BFFF) : Colors.white,
                              ),
                            ),
                            subtitle: Row(
                              children: [
                                Text(
                                  track.artist,
                                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                                ),
                                if (isSavedOffline) ...[
                                  const SizedBox(width: 6),
                                  const Icon(Icons.offline_pin_rounded, size: 14, color: Colors.greenAccent),
                                  const SizedBox(width: 2),
                                  const Text('Офлайн', style: TextStyle(color: Colors.greenAccent, fontSize: 11)),
                                ],
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Кнопка Офлайн-завантаження
                                if (downloadP != null)
                                  Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        value: downloadP > 0 ? downloadP : null,
                                        strokeWidth: 2.5,
                                        color: const Color(0xFF00BFFF),
                                      ),
                                    ),
                                  )
                                else
                                  IconButton(
                                    tooltip: isSavedOffline ? 'Збережено в офлайн (натисніть для опцій)' : 'Зберегти в офлайн',
                                    icon: Icon(
                                      isSavedOffline
                                          ? Icons.offline_pin_rounded
                                          : Icons.download_rounded,
                                      color: isSavedOffline
                                          ? Colors.greenAccent
                                          : Colors.white60,
                                    ),
                                    onPressed: () => _toggleSaveOffline(track),
                                  ),

                                IconButton(
                                  icon: Icon(
                                    isSelected && isPlaying
                                        ? Icons.pause_circle_filled_rounded
                                        : Icons.play_circle_fill_rounded,
                                    color: isSelected
                                        ? const Color(0xFF00BFFF)
                                        : const Color(0xFFFFD700),
                                    size: 32,
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
                          const Icon(Icons.offline_pin_rounded, size: 12, color: Colors.greenAccent),
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
  // ВКЛАДКА 3: ПРОФІЛЬ / ПІДТРИМКА
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
                          user != null
                              ? 'Тариф: ${user.plan.toUpperCase()}'
                              : 'Увійдіть, щоб зняти обмеження прослуховування',
                          style: TextStyle(
                            fontSize: 13,
                            color: user != null ? const Color(0xFFFFD700) : Colors.white60,
                          ),
                        ),
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
          const SizedBox(height: 20),

          // Підтримка артиста / банка Monobank
          Card(
            color: const Color(0xFF0F172A),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.favorite_rounded, color: Colors.redAccent),
                      SizedBox(width: 10),
                      Text(
                        'Підтримка «Тризуб МС»',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Підтримайте створення нових українських військово-патріотичних треків донатом на банку Monobank.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD700),
                      foregroundColor: Colors.black,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    icon: const Icon(Icons.savings_rounded),
                    label: const Text('Відкрити банку Monobank', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: () async {
                      final uri = Uri.parse('https://send.monobank.ua/jar/3683xHhA5b');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
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
  String _waitType = ''; // '2fa', 'tg', 'google'
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
