package com.imtaqin.andropi

import android.app.Notification
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
            if (on) context.startForegroundService(intent)
            else context.stopService(intent)
        }

        /** Refreshes the ongoing notification while it is shown (current chat and tool). */
        fun update(context: Context, title: String?, text: String?) {
            if (active) setActive(context, true, text, title, stoppable = true)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Notifications.ensureChannels(this)
        val stop = PendingIntent.getBroadcast(
            this, 0, Intent(this, StopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, Notifications.ACTIVITY)
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setContentTitle(intent?.getStringExtra("title") ?: "AndroPI")
            .setContentText(
                intent?.getStringExtra("text") ?: Notifications.t(this, "Agent is working", "Agent sedang bekerja")
            )
            .setContentIntent(Notifications.openIntent(this, 0, mapOf("action" to "open_chat")))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (intent?.getBooleanExtra("stoppable", false) == true) {
            builder.addAction(
                Notification.Action.Builder(null, Notifications.t(this, "Stop", "Hentikan"), stop).build()
            )
        }
        val notification = builder.build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(ID, notification)
        }
        return START_NOT_STICKY
    }
}
