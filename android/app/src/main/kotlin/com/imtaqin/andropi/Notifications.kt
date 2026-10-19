package com.imtaqin.andropi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * The app's notifications: one channel per kind so each can be muted on its own, texts in the app's language,
 * and taps or buttons that open the right place. A tap carries a launch map (e.g. {"action": "open_chat", "path":
 * ...}) that Flutter picks up through takeLaunch; a per-install token keeps other apps from sending those.
 */
object Notifications {
    const val APPROVALS = "approvals"
    const val CHATS = "chats"
    const val TASKS = "tasks"
    const val APP_UPDATES = "app_updates"
    const val SYNC = "sync"
    const val ACTIVITY = "agent"
    const val EXTRA_LAUNCH = "launch"
    const val EXTRA_TOKEN = "launch_token"

    /** True when the app is set to Bahasa Indonesia (ui.json, written by the Flutter side). */
    fun indonesian(context: Context): Boolean = try {
        JSONObject(File(context.filesDir, "ui.json").readText()).optString("language") == "id"
    } catch (e: Exception) {
        false
    }

    fun t(context: Context, en: String, id: String) = if (indonesian(context)) id else en

    fun token(context: Context): String {
        val prefs = context.getSharedPreferences("notifications", Context.MODE_PRIVATE)
        return prefs.getString("token", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("token", it).apply()
        }
    }

    /** Creates (or renames, after a language change) the channels. */
    fun ensureChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        // The old catch-all channel; its kinds now have their own.
        manager.deleteNotificationChannel("updates")
        fun channel(id: String, en: String, idName: String, importance: Int) =
            NotificationChannel(id, t(context, en, idName), importance)
        manager.createNotificationChannels(
            listOf(
                channel(APPROVALS, "Approvals", "Persetujuan", NotificationManager.IMPORTANCE_HIGH),
                channel(CHATS, "Chat finished", "Chat selesai", NotificationManager.IMPORTANCE_DEFAULT),
                channel(TASKS, "Background tasks", "Background task", NotificationManager.IMPORTANCE_DEFAULT),
                channel(APP_UPDATES, "App updates", "Update aplikasi", NotificationManager.IMPORTANCE_DEFAULT),
                channel(SYNC, "GitHub sync", "Sinkron GitHub", NotificationManager.IMPORTANCE_LOW),
                channel(ACTIVITY, "Agent activity", "Aktivitas agent", NotificationManager.IMPORTANCE_LOW),
            )
        )
    }

    /** Opens the app with [launch] (null: just open it). */
    fun openIntent(context: Context, requestCode: Int, launch: Map<String, Any?>?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(MainActivity.ACTION_OPEN)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (launch != null) {
            intent.putExtra(EXTRA_LAUNCH, JSONObject(launch).toString()).putExtra(EXTRA_TOKEN, token(context))
        }
        return PendingIntent.getActivity(
            context, requestCode, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** The launch map of a notification tap, if it really came from one of ours. */
    fun launchOf(context: Context, intent: Intent): Map<String, Any?>? {
        if (intent.getStringExtra(EXTRA_TOKEN) != token(context)) return null
        val json = JSONObject(intent.getStringExtra(EXTRA_LAUNCH) ?: return null)
        return json.keys().asSequence().associateWith { json.opt(it).takeUnless { v -> v == JSONObject.NULL } }
    }

    /**
     * Posts a notification. [actions] are (label, launch) pairs shown as buttons. Silently skipped when the user
     * has not allowed notifications.
     */
    fun post(
        context: Context,
        id: Int,
        channel: String,
        title: String,
        body: String,
        launch: Map<String, Any?>? = null,
        actions: List<Pair<String, Map<String, Any?>>> = emptyList(),
    ) {
        ensureChannels(context)
        val builder = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(openIntent(context, id, launch))
            .setAutoCancel(true)
        // Approvals name commands and files; keep them off the lock screen.
        if (channel == APPROVALS) builder.setVisibility(Notification.VISIBILITY_PRIVATE)
        actions.forEachIndexed { i, (label, action) ->
            builder.addAction(
                Notification.Action.Builder(null, label, openIntent(context, id * 10 + i + 1, action)).build()
            )
        }
        context.getSystemService(NotificationManager::class.java).notify(id, builder.build())
    }

    fun cancel(context: Context, id: Int) {
        context.getSystemService(NotificationManager::class.java).cancel(id)
    }
}

/** "Stop" on the agent's ongoing notification: aborts the run without opening the app. */
class StopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (AgentRuntime.isRunning) AgentRuntime.send("""{"type":"abort"}""")
    }
}
