import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_service.dart';

class OfflineManager {
  static final OfflineManager instance = OfflineManager._internal();
  OfflineManager._internal();

  Directory? _baseDir;
  final List<TrackModel> _savedTracks = [];

  List<TrackModel> get savedTracks => List.unmodifiable(_savedTracks);

  Future<void> init() async {
    try {
      _baseDir = await getApplicationDocumentsDirectory();
      final audioDir = Directory('${_baseDir!.path}/offline_audio');
      if (!await audioDir.exists()) {
        await audioDir.create(recursive: true);
      }
      final coversDir = Directory('${_baseDir!.path}/offline_covers');
      if (!await coversDir.exists()) {
        await coversDir.create(recursive: true);
      }
      await _loadMetadata();
    } catch (e) {
      // ignore
    }
  }

  File _getMetadataFile() {
    return File('${_baseDir!.path}/offline_tracks.json');
  }

  Future<void> _loadMetadata() async {
    _savedTracks.clear();
    final file = _getMetadataFile();
    if (await file.exists()) {
      try {
        final jsonStr = await file.readAsString();
        final list = jsonDecode(jsonStr) as List;
        for (final item in list) {
          final track = TrackModel.fromJson(item as Map<String, dynamic>);
          final audioFile = File(getAudioFilePath(track.id));
          if (await audioFile.exists() && await audioFile.length() > 0) {
            _savedTracks.add(track);
          }
        }
      } catch (e) {
        // ignore
      }
    }
  }

  Future<void> _saveMetadata() async {
    final file = _getMetadataFile();
    final list = _savedTracks.map((t) => t.toJson()).toList();
    await file.writeAsString(jsonEncode(list));
  }

  String getAudioFilePath(int trackId) {
    return '${_baseDir?.path ?? ""}/offline_audio/$trackId.mp3';
  }

  bool isTrackSaved(int trackId) {
    if (_baseDir == null) return false;
    final file = File(getAudioFilePath(trackId));
    return file.existsSync() && file.lengthSync() > 0;
  }

  Future<bool> saveTrackOffline(
    TrackModel track, {
    Function(double progress)? onProgress,
  }) async {
    if (_baseDir == null) await init();

    final audioFile = File(getAudioFilePath(track.id));
    final tempFile = File('${_baseDir!.path}/offline_audio/temp_${track.id}.mp3');

    try {
      final streamUrl = ApiService.getStreamUrl(track.id);
      final request = http.Request('GET', Uri.parse(streamUrl));
      request.headers.addAll({
        'User-Agent': 'TryzubPlayer-Multiplatform/${ApiService.appVersion}',
        'X-App-Version': ApiService.appVersion,
        if (ApiService.token != null) 'X-App-Token': ApiService.token!,
      });

      final response = await request.send();
      if (response.statusCode != 200) {
        return false;
      }

      final totalBytes = response.contentLength ?? 0;
      int receivedBytes = 0;

      if (await tempFile.exists()) await tempFile.delete();
      final sink = tempFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress((receivedBytes / totalBytes).clamp(0.0, 1.0));
        }
      }

      await sink.flush();
      await sink.close();

      if (await audioFile.exists()) await audioFile.delete();
      await tempFile.rename(audioFile.path);

      // Кешуємо обкладинку
      if (track.coverImage != null && track.coverImage!.isNotEmpty) {
        try {
          final coverFile = File('${_baseDir!.path}/offline_covers/${track.coverImage}');
          if (!await coverFile.exists()) {
            final coverRes = await http.get(Uri.parse(track.coverUrl));
            if (coverRes.statusCode == 200) {
              await coverFile.writeAsBytes(coverRes.bodyBytes);
            }
          }
        } catch (_) {}
      }

      _savedTracks.removeWhere((t) => t.id == track.id);
      _savedTracks.add(track);
      await _saveMetadata();
      return true;
    } catch (e) {
      if (await tempFile.exists()) await tempFile.delete();
      return false;
    }
  }

  Future<bool> deleteTrackOffline(int trackId) async {
    try {
      final file = File(getAudioFilePath(trackId));
      if (await file.exists()) {
        await file.delete();
      }
      _savedTracks.removeWhere((t) => t.id == trackId);
      await _saveMetadata();
      return true;
    } catch (e) {
      return false;
    }
  }

  String getTotalSizeFormatted() {
    int totalBytes = 0;
    for (final track in _savedTracks) {
      final file = File(getAudioFilePath(track.id));
      if (file.existsSync()) {
        totalBytes += file.lengthSync();
      }
    }
    if (totalBytes < 1024 * 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} КБ';
    } else {
      return '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
    }
  }
}
