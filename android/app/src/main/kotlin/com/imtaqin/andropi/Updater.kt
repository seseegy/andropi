package com.imtaqin.andropi

import android.Manifest
import android.app.DownloadManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Self-update for the GitHub build. The APK is fetched by the system DownloadManager, so the download keeps going
 * (and resumes after network drops) when the app is closed or killed; the download id lives in SharedPreferences
 * so the app picks it up again on the next launch. The Play build removes REQUEST_INSTALL_PACKAGES and never
 * calls this.
 */
object Updater {
    private const val PREFS = "updater"
    private const val CHANNEL = "app_updates"
    private const val NOTIFICATION_ID = 4200

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun downloads(context: Context) = context.getSystemService(DownloadManager::class.java)

    private fun dir(context: Context) =
        File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "updates").apply { mkdirs() }

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "andropi/updater").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> result.success(info(app))
                    "prefs" -> result.success(prefs(app).all.filterKeys { it.startsWith("pref.") }
                        .mapKeys { it.key.removePrefix("pref.") })
                    "setPref" -> {
                        val key = "pref.${call.argument<String>("key")}"
                        prefs(app).edit().apply {
                            when (val value = call.argument<Any>("value")) {
                                null -> remove(key)
                                is Boolean -> putBoolean(key, value)
                                is Int -> putLong(key, value.toLong())
                                is Long -> putLong(key, value)
                                else -> putString(key, value.toString())
                            }
                        }.apply()
                        result.success(null)
                    }
                    "download" -> result.success(
                        download(
                            app,
                            call.argument<String>("url")!!,
                            call.argument<String>("version")!!,
                            call.argument<String>("name")!!,
                            call.argument<String>("sha256"),
                        )
                    )
                    "status" -> result.success(status(app))
                    "cancel" -> {
                        clear(app)
                        result.success(status(app))
                    }
                    // Hashing a large APK takes a moment; keep it off the UI thread.
                    "install" -> Thread {
                        val outcome = try {
                            install(app)
                        } catch (e: Exception) {
                            "error:${e.message}"
                        }
                        Handler(Looper.getMainLooper()).post { result.success(outcome) }
                    }.start()
                    "openInstallSettings" -> {
                        openInstallSettings(app)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("updater", e.message, null)
            }
        }
    }

    private fun info(context: Context): Map<String, Any?> {
        val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
        return mapOf(
            "version" to pkg.versionName,
            "build" to PackageInfoCompat.getLongVersionCode(pkg),
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "supported" to declares(context, Manifest.permission.REQUEST_INSTALL_PACKAGES),
            "canInstall" to canInstall(context),
        )
    }

    private fun declares(context: Context, permission: String): Boolean {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        return info.requestedPermissions?.contains(permission) == true
    }

    private fun canInstall(context: Context) = context.packageManager.canRequestPackageInstalls()

    /** Starts a fresh download, replacing any earlier one. */
    private fun download(context: Context, url: String, version: String, name: String, sha256: String?): Map<String, Any?> {
        clear(context)
        val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
        // A leftover file with the same name would make DownloadManager pick another name.
        File(dir(context), safeName).delete()
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle("AndroPI $version")
            .setDescription("Downloading update")
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
            .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS, "updates/$safeName")
        val id = downloads(context).enqueue(request)
        prefs(context).edit()
            .putLong("id", id)
            .putString("version", version)
            .putString("sha256", sha256?.lowercase())
            .apply()
        return status(context)
    }

    /** The current download, or status "none". */
    fun status(context: Context): Map<String, Any?> {
        val prefs = prefs(context)
        val id = prefs.getLong("id", -1)
        if (id < 0) return mapOf("status" to "none")
        downloads(context).query(DownloadManager.Query().setFilterById(id))?.use { c ->
            if (!c.moveToFirst()) {
                // Removed outside the app (e.g. from the system Downloads list).
                clear(context)
                return mapOf("status" to "none")
            }
            val state = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))?.let { local ->
                Uri.parse(local).path?.let { prefs.edit().putString("file", it).apply() }
            }
            return mapOf(
                "status" to when (state) {
                    DownloadManager.STATUS_PENDING -> "pending"
                    DownloadManager.STATUS_RUNNING -> "running"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_SUCCESSFUL -> "done"
                    else -> "failed"
                },
                "reason" to c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                "downloaded" to c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                "total" to c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                "version" to prefs.getString("version", null),
            )
        }
        return mapOf("status" to "none")
    }

    /** Cancels a running download and deletes what was fetched. */
    fun clear(context: Context) {
        val prefs = prefs(context)
        val id = prefs.getLong("id", -1)
        if (id >= 0) downloads(context).remove(id)
        prefs.getString("file", null)?.let { File(it).delete() }
        prefs.edit().remove("id").remove("version").remove("file").remove("sha256").apply()
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    /** "started", "permission" (sent to the system setting first), "missing", "corrupt" or "error:…". */
    private fun install(context: Context): String {
        val prefs = prefs(context)
        val file = prefs.getString("file", null)?.let(::File)
        if (file == null || !file.exists() || status(context)["status"] != "done") return "missing"
        val expected = prefs.getString("sha256", null)
        if (!expected.isNullOrEmpty() && sha256(file) != expected) {
            clear(context)
            return "corrupt"
        }
        if (!canInstall(context)) {
            openInstallSettings(context)
            return "permission"
        }
        val uri = FileProvider.getUriForFile(context, "com.imtaqin.andropi.files", file)
        context.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        return "started"
    }

    private fun openInstallSettings(context: Context) {
        context.startActivity(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** Lets the user know when a download finishes while the app is in the background. */
    fun onDownloadComplete(context: Context, id: Long) {
        val prefs = prefs(context)
        if (id != prefs.getLong("id", -1)) return
        val ok = status(context)["status"] == "done"
        val version = prefs.getString("version", "") ?: ""
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "App updates", NotificationManager.IMPORTANCE_DEFAULT))
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val open = PendingIntent.getActivity(
            context, NOTIFICATION_ID,
            Intent(context, MainActivity::class.java)
                .setAction(MainActivity.ACTION_UPDATE)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = android.app.Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_agent)
            .setContentTitle(if (ok) "AndroPI $version is ready" else "AndroPI update failed")
            .setContentText(if (ok) "Tap to install the update" else "Tap to try again")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }
}

/** DownloadManager tells the app that started a download when it finishes, even if the app is not running. */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        Updater.onDownloadComplete(context, intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1))
    }
}
