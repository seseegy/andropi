package com.imtaqin.andropi

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the app process alive while the agent is working so a long run is not
 * killed when the user switches apps. The process itself lives in AgentRuntime.
 */
class AgentService : Service() {
    companion object {
        private const val ID = 1
        private var active = false
        private var stoppable = false

        /**
         * [stoppable]: the agent itself is working (not just background tasks), so the notification offers Stop.
         * [title] and [text] default to a generic "working" line.
         */
        fun setActive(
            context: Context,
            on: Boolean,
            text: String? = null,
            title: String? = null,
            stoppable: Boolean = false,
        ) {
            val intent = Intent(context, AgentService::class.java)
                .putExtra("text", text)
                .putExtra("title", title)
                .putExtra("stoppable", stoppable)
            active = on
            this.stoppable = stoppable
            if (on) context.startForegroundService(intent)
            else context.stopService(intent)
        }

        /**
         * Refreshes the ongoing notification (current chat and tool). Posted straight to the notification manager:
         * starting the service again from the background is not allowed on Android 12+.
         */
        fun update(context: Context, title: String?, text: String?) {
            if (!active) return
            context.getSystemService(NotificationManager::class.java)
                .notify(ID, build(context, title, text, stoppable))
        }

        private fun build(context: Context, title: String?, text: String?, stoppable: Boolean): Notification {
            Notifications.ensureChannels(context)
            val builder = Notification.Builder(context, Notifications.ACTIVITY)
                .setSmallIcon(R.drawable.ic_stat_agent)
                .setContentTitle(title ?: "AndroPI")
                .setContentText(text ?: Notifications.t(context, "Agent is working", "Agent sedang bekerja"))
                .setContentIntent(Notifications.openIntent(context, 0, mapOf("action" to "open_chat")))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
            if (stoppable) {
                val stop = PendingIntent.getBroadcast(
                    context, 0, Intent(context, StopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
                )
                builder.addAction(
                    Notification.Action.Builder(null, Notifications.t(context, "Stop", "Hentikan"), stop).build()
                )
            }
            return builder.build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = build(
            this,
            intent?.getStringExtra("title"),
            intent?.getStringExtra("text"),
            intent?.getBooleanExtra("stoppable", false) == true,
        )
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        return START_NOT_STICKY
    }
}
