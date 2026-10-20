package com.tryzubmc.officialmusic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.tryzubmc.player/nowplaying"
    private val NOTIFICATION_CHANNEL_ID = "tryzub_music_playback"
    private val NOTIFICATION_ID = 777

    private var methodChannel: MethodChannel? = null
    private var mediaSession: MediaSession? = null
    private var notificationManager: NotificationManager? = null

    private val mediaActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_PLAY -> runOnUiThread { methodChannel?.invokeMethod("onRemotePlay", null) }
                ACTION_PAUSE -> runOnUiThread { methodChannel?.invokeMethod("onRemotePause", null) }
                ACTION_TOGGLE -> runOnUiThread { methodChannel?.invokeMethod("onRemoteToggle", null) }
                ACTION_NEXT -> runOnUiThread { methodChannel?.invokeMethod("onRemoteNext", null) }
                ACTION_PREV -> runOnUiThread { methodChannel?.invokeMethod("onRemotePrev", null) }
            }
        }
    }

    companion object {
        const val ACTION_PLAY = "com.tryzubmc.player.ACTION_PLAY"
        const val ACTION_PAUSE = "com.tryzubmc.player.ACTION_PAUSE"
        const val ACTION_TOGGLE = "com.tryzubmc.player.ACTION_TOGGLE"
        const val ACTION_NEXT = "com.tryzubmc.player.ACTION_NEXT"
        const val ACTION_PREV = "com.tryzubmc.player.ACTION_PREV"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
        setupMediaSession()

        val filter = IntentFilter().apply {
            addAction(ACTION_PLAY)
            addAction(ACTION_PAUSE)
            addAction(ACTION_TOGGLE)
            addAction(ACTION_NEXT)
            addAction(ACTION_PREV)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(mediaActionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(mediaActionReceiver, filter)
        }

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

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Відтворення музики Тризуб МС",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Керування відтворенням на заблокованому екрані"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notificationManager?.createNotificationChannel(channel)
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

    private fun updateAndroidNowPlaying(
        title: String,
        artist: String,
        isPlaying: Boolean,
        duration: Double,
        position: Double
    ) {
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

            showMediaNotification(title, artist, isPlaying)
        }
    }

    private fun getPendingAction(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(action).setPackage(packageName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getBroadcast(this, requestCode, intent, flags)
    }

    private fun showMediaNotification(title: String, artist: String, isPlaying: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val contentIntent = PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                },
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            )

            val prevPending = getPendingAction(ACTION_PREV, 1)
            val togglePending = getPendingAction(ACTION_TOGGLE, 2)
            val nextPending = getPendingAction(ACTION_NEXT, 3)

            val playPauseIcon = if (isPlaying) {
                android.R.drawable.ic_media_pause
            } else {
                android.R.drawable.ic_media_play
            }
            val playPauseTitle = if (isPlaying) "Пауза" else "Грати"

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            } else {
                Notification.Builder(this)
            }

            builder
                .setContentTitle(title)
                .setContentText(artist)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(contentIntent)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOngoing(isPlaying)
                .addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_media_previous,
                        "Попередній",
                        prevPending
                    ).build()
                )
                .addAction(
                    Notification.Action.Builder(
                        playPauseIcon,
                        playPauseTitle,
                        togglePending
                    ).build()
                )
                .addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_media_next,
                        "Наступний",
                        nextPending
                    ).build()
                )
                .setStyle(
                    Notification.MediaStyle()
                        .setMediaSession(mediaSession?.sessionToken)
                        .setShowActionsInCompactView(0, 1, 2)
                )

            notificationManager?.notify(NOTIFICATION_ID, builder.build())
        }
    }

    private fun clearAndroidNowPlaying() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            mediaSession?.isActive = false
            notificationManager?.cancel(NOTIFICATION_ID)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(mediaActionReceiver)
        } catch (e: Exception) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            mediaSession?.release()
            mediaSession = null
            notificationManager?.cancel(NOTIFICATION_ID)
        }
    }
}
