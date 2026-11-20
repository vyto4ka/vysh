package uwu.vyto4ka.vysh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager

/// Удерживает процесс, пока во вкладках есть живые SSH-сессии.
///
/// Сервис сам владеет wake lock: берёт его при старте, продлевает по таймеру,
/// пока работает, и отпускает при остановке. Сессии живут в Dart-движке
/// Activity, поэтому после гибели процесса восстановить их нечем - сервис
/// не перезапускается (START_NOT_STICKY), а Activity при уничтожении
/// останавливает его.
class SshForegroundService : Service() {
    companion object {
        private const val CHANNEL_ID = "vysh_ssh_foreground"
        private const val NOTIFICATION_ID = 40401

        /// Wake lock берётся на этот срок и продлевается чуть раньше.
        private const val WAKE_LOCK_MS = 30 * 60 * 1000L
        private const val RENEW_MS = 25 * 60 * 1000L

        @Volatile
        private var running = false

        fun start(context: Context, hostTitle: String? = null): Boolean {
            if (running) {
                return try {
                    val title = hostTitle ?: context.getString(R.string.ssh_connected)
                    val manager = context.getSystemService(NotificationManager::class.java)
                    manager?.notify(NOTIFICATION_ID, buildNotification(context, title))
                    true
                } catch (_: Exception) {
                    false
                }
            }
            val intent = Intent(context, SshForegroundService::class.java).apply {
                if (hostTitle != null) putExtra("title", hostTitle)
            }
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (_: Exception) {
                // Например, ForegroundServiceStartNotAllowedException из фона.
                false
            }
        }

        fun stop(context: Context) {
            running = false
            try {
                val intent = Intent(context, SshForegroundService::class.java)
                context.stopService(intent)
            } catch (_: Exception) {}
        }

        private fun buildNotification(context: Context, hostTitle: String): Notification {
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val pendingIntent = if (launchIntent != null) {
                PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
                )
            } else null

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            builder
                .setContentTitle("vysh: $hostTitle")
                .setContentText(context.getString(R.string.ssh_notification_text))
                .setSmallIcon(R.drawable.ic_stat_vysh)
                .setOngoing(true)

            if (pendingIntent != null) {
                builder.setContentIntent(pendingIntent)
            }

            return builder.build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val renew = object : Runnable {
        override fun run() {
            acquireWakeLock()
            handler.postDelayed(this, RENEW_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: getString(R.string.ssh_connected)
        val notification = buildNotification(this, title)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                // Android 14+: specialUse - у dataSync на Android 15 лимит
                // 6 часов в сутки, после него система рвёт SSH-сессии.
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
        } catch (_: Exception) {
            // Без foreground-режима сервис бесполезен и будет убит системой.
            running = false
            stopSelf()
            return START_NOT_STICKY
        }

        handler.removeCallbacks(renew)
        renew.run()
        return START_NOT_STICKY
    }

    /// Лимит времени для dataSync (на Android 14+ сервис идёт как specialUse,
    /// лимита нет). По истечении нужно остановиться, иначе система завершит
    /// приложение.
    override fun onTimeout(startId: Int, fgsType: Int) {
        running = false
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        handler.removeCallbacks(renew)
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        wakeLock = null
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        try {
            val lock = wakeLock ?: (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "vysh:ssh_session")
                .apply { setReferenceCounted(false) }
                .also { wakeLock = it }
            lock.acquire(WAKE_LOCK_MS)
        } catch (_: Exception) {}
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.ssh_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.ssh_channel_description)
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }
}
