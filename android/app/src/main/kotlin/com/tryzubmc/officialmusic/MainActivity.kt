package com.tryzubmc.officialmusic

import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.tryzubmc.player/nowplaying"
    private var methodChannel: MethodChannel? = null
    private var mediaSession: MediaSession? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        setupMediaSession()

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateNowPlaying" -> {
                    val title = call.argument<String>("title") ?: "Тризуб МС"
                    val artist = call.argument<String>("artist") ?: "Офіційний виконавець"
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val duration = call.argument<Double>("duration") ?: 0.0
                    val position = call.argument<Double>("position") ?: 0.0

                    updateAndroidNowPlaying(title, artist, isPlaying, duration, position)
                    result.success(true)
                }
                "clearNowPlaying" -> {
                    clearAndroidNowPlaying()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupMediaSession() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            mediaSession = MediaSession(this, "TryzubMediaSession").apply {
                setCallback(object : MediaSession.Callback() {
                    override fun onPlay() {
                        runOnUiThread { methodChannel?.invokeMethod("onRemotePlay", null) }
                    }
                    override fun onPause() {
                        runOnUiThread { methodChannel?.invokeMethod("onRemotePause", null) }
                    }
                    override fun onSkipToNext() {
                        runOnUiThread { methodChannel?.invokeMethod("onRemoteNext", null) }
                    }
                    override fun onSkipToPrevious() {
                        runOnUiThread { methodChannel?.invokeMethod("onRemotePrev", null) }
                    }
                    override fun onSeekTo(pos: Long) {
                        runOnUiThread { methodChannel?.invokeMethod("onRemoteSeek", pos / 1000.0) }
                    }
                })
                isActive = true
            }
        }
    }

    private fun updateAndroidNowPlaying(title: String, artist: String, isPlaying: Boolean, duration: Double, position: Double) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && mediaSession != null) {
            val state = if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED
            val playbackSpeed = if (isPlaying) 1.0f else 0.0f

            val playbackState = PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_SEEK_TO
                )
                .setState(state, (position * 1000).toLong(), playbackSpeed)
                .build()

            mediaSession?.setPlaybackState(playbackState)

            val metadata = MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, (duration * 1000).toLong())
                .build()

            mediaSession?.setMetadata(metadata)
            mediaSession?.isActive = true
        }
    }

    private fun clearAndroidNowPlaying() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            mediaSession?.isActive = false
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            mediaSession?.release()
            mediaSession = null
        }
    }
}
