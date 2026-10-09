package ru.furya.starty

import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Самообновление — как у Дневника, только канал не облако, а сайт приложения:
 * <сайт>/app/latest.json и рядом сборка.
 *
 * Раз в час (и при каждом открытии) приложение смотрит описание; новую сборку
 * скачивает, сверяет размер и хеш, проверяет, что это та же программа, номер сходится
 * и она подписана тем же ключом, и ставит сама — без вопросов (Android 12+ разрешает
 * приложению тихо обновлять себя). Пока приложение на экране, установка ждёт: она
 * закрыла бы его на глазах. Встаёт, как только его свернут.
 */
object Updater {
    private const val BASE = "https://xfurya.github.io/Starty/app/"
    private const val PREFS = "update"
    private const val JOB_ID = 7311
    private const val CHANNEL = "update"
    private const val NOTE_ID = 7312
    const val ACTION_STATUS = "ru.furya.starty.UPDATE_STATUS"
    const val EXTRA_INSTALL = "update_install"
    private val FILE_NAME = Regex("^[a-z0-9][a-z0-9.\\-]{0,80}\\.apk$")
    private val SHA = Regex("^[0-9a-f]{64}$")
    private const val MAX_APK = 96L shl 20

    /** Интерфейс подписывается, чтобы видеть состояние сразу. */
    @Volatile var listener: (() -> Unit)? = null
    private val lock = Any()
    @Volatile private var checking = false

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun dir(ctx: Context) = File(ctx.filesDir, "update").apply { mkdirs() }
    private fun changed() { listener?.invoke() }

    @Suppress("DEPRECATION")
    private fun installedCode(ctx: Context): Long {
        val i = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) i.longVersionCode else i.versionCode.toLong()
    }

    private fun installedName(ctx: Context): String =
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: ""

    // ---------- сеть ----------

    private class HttpError(val code: Int) : IOException("HTTP $code")

    private fun open(url: String): HttpURLConnection {
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        c.useCaches = false
        c.setRequestProperty("Cache-Control", "no-cache")
        c.instanceFollowRedirects = true
        if (c.responseCode != 200) {
            val code = c.responseCode
            c.disconnect()
            throw HttpError(code)
        }
        return c
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { s ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = s.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun sha256(b: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    /**
     * Проверить сайт и, если есть новее, скачать. Ставит сразу, если [install] и
     * приложение не на экране. Вызывается не из главного потока.
     */
    fun run(ctx: Context, install: Boolean) {
        if (checking) return
        synchronized(lock) {
            checking = true
            changed()
            var err = ""
            try {
                err = fetch(ctx)
            } catch (e: Exception) {
                err = netMessage(e)
            }
            prefs(ctx).edit().putLong("checkedAt", System.currentTimeMillis()).putString("error", err).apply()
            checking = false
            changed()
        }
        if (install) installQuietly(ctx)
    }

    private fun netMessage(e: Exception): String = when (e) {
        is java.net.UnknownHostException, is java.net.ConnectException -> "нет связи"
        is java.net.SocketTimeoutException -> "сайт не ответил вовремя"
        is HttpError -> "сайт ответил ${e.code}"
        is javax.net.ssl.SSLException -> "защищённое соединение не установилось"
        else -> e.message ?: e.javaClass.simpleName
    }

    /** Возвращает текст ошибки или пустую строку. */
    private fun fetch(ctx: Context): String {
        val text = try {
            open(BASE + "latest.json?t=" + System.currentTimeMillis() / 60_000).let { c ->
                try { c.inputStream.use { String(it.readBytes(), Charsets.UTF_8) } } finally { c.disconnect() }
            }
        } catch (e: HttpError) {
            if (e.code == 404) { dropReady(ctx); return "" }
            throw e
        }
        val body = try { JSONObject(text) } catch (_: Exception) { return "описание обновления не читается" }
        val version = body.optString("version")
        val code = body.optLong("code")
        val apk = body.optJSONObject("android") ?: return ""
        if (version.isBlank() || code <= 0) return "описание обновления испорчено"
        if (code <= installedCode(ctx)) { dropReady(ctx); return "" }
        val name = apk.optString("file")
        val size = apk.optLong("size")
        val sha = apk.optString("sha256").lowercase()
        if (!FILE_NAME.matches(name) || size <= 0 || size > MAX_APK || !SHA.matches(sha)) return "описание обновления испорчено"

        val p = prefs(ctx)
        val dst = File(dir(ctx), "starty-$code.apk")
        if (p.getString("readySha", "") == sha && dst.isFile && dst.length() == size && sha256(dst) == sha) return ""
        dropReady(ctx)
        // Сразу видно, что идёт загрузка, а не «ничего нет».
        p.edit().putString("dl", version).apply(); changed()
        val tmp = File(dir(ctx), "download.part")
        try {
            val md = MessageDigest.getInstance("SHA-256")
            var got = 0L
            val c = open(BASE + name)
            try {
                c.inputStream.use { inp ->
                    tmp.outputStream().use { out ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = inp.read(buf)
                            if (n < 0) break
                            got += n
                            if (got > size) return "сборка больше, чем в описании"
                            md.update(buf, 0, n)
                            out.write(buf, 0, n)
                        }
                    }
                }
            } finally { c.disconnect() }
            if (got == 0L) return "сайт отдал сборку пустой"
            if (got != size) return "сборка скачалась не целиком"
            if (md.digest().joinToString("") { "%02x".format(it) } != sha) return "сборка скачалась с ошибками"
            // Хеш сошёлся — файл целый; кладём под настоящим именем (.apk нужно разбору).
            if (!tmp.renameTo(dst)) return "не получилось сохранить сборку"
        } finally {
            p.edit().remove("dl").apply()
            tmp.delete()
        }
        val why = checkApk(ctx, dst, code)
        if (why.isNotEmpty()) { dst.delete(); return why }
        p.edit()
            .putString("readyVersion", version)
            .putLong("readyCode", code)
            .putString("readyNotes", body.optString("notes").replace(Regex("\\s+"), " ").trim().take(200))
            .putString("readySha", sha)
            .putString("readyFile", dst.name)
            .putString("wait", "")
            .putInt("tries", 0)
            .apply()
        return ""
    }

    /** Та же программа, новее, подписана тем же ключом — иначе и пробовать нечего. */
    @Suppress("DEPRECATION")
    @SuppressLint("PackageManagerGetSignatures")
    private fun checkApk(ctx: Context, f: File, code: Long): String {
        val pm = ctx.packageManager
        val flag = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val info = pm.getPackageArchiveInfo(f.path, flag) ?: return "сборка не читается"
        if (info.packageName != ctx.packageName) return "на сайте чужая программа"
        val v = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        if (v != code) return "номер сборки не сходится с описанием"
        val mine = pm.getPackageInfo(ctx.packageName, flag)
        // Если подпись файла не прочиталась, решит сама система: чужой ключ она не поставит поверх.
        val theirs = signers(info)
        if (theirs.isNotEmpty() && theirs != signers(mine)) return "сборка подписана не тем ключом"
        return ""
    }

    @Suppress("DEPRECATION")
    private fun signers(i: PackageInfo): Set<String> {
        val sigs = if (Build.VERSION.SDK_INT >= 28) i.signingInfo?.let {
            if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory
        } else i.signatures
        return sigs.orEmpty().map { sha256(it.toByteArray()) }.toSet()
    }

    private fun dropReady(ctx: Context) {
        dir(ctx).listFiles()?.forEach { it.delete() }
        prefs(ctx).edit().remove("readyVersion").remove("readyCode").remove("readyNotes").remove("readySha")
            .remove("readyFile").remove("wait").remove("tries").apply()
    }

    /** Скачанное и проверенное обновление или null. */
    private fun ready(ctx: Context): File? {
        val p = prefs(ctx)
        if (p.getLong("readyCode", 0) <= installedCode(ctx)) return null
        val f = File(dir(ctx), p.getString("readyFile", "") ?: "")
        return if (f.isFile && f.name.endsWith(".apk")) f else null
    }

    // ---------- установка ----------

    /**
     * Поставить без человека: только если приложение не на экране, система не ждёт
     * подтверждения (оно уже висит уведомлением) и попыток было немного — иначе это вечный круг.
     */
    fun installQuietly(ctx: Context) {
        val p = prefs(ctx)
        if (MainActivity.visible || ready(ctx) == null) return
        if (p.getString("wait", "") == "confirm" || p.getInt("tries", 0) >= 3) return
        install(ctx, fromUser = false)
    }

    /** Ставит скачанное. [fromUser] — нажали «Обновить сейчас»: после установки откроем снова. */
    fun install(ctx: Context, fromUser: Boolean): String {
        val f = ready(ctx) ?: return "обновление ещё не скачано"
        val p = prefs(ctx)
        // Проверка ещё раз: файл мог испортиться с тех пор, как скачан.
        if (sha256(f) != p.getString("readySha", "")) { dropReady(ctx); return "скачанное обновление испортилось" }
        p.edit().putBoolean("reopen", fromUser).putInt("tries", p.getInt("tries", 0) + 1).putString("wait", "").apply()
        return try {
            val pi = ctx.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(ctx.packageName)
            if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            val id = pi.createSession(params)
            pi.openSession(id).use { s ->
                s.openWrite("base.apk", 0, f.length()).use { out ->
                    f.inputStream().use { it.copyTo(out) }
                    s.fsync(out)
                }
                val cb = Intent(ctx, UpdateReceiver::class.java).setAction(ACTION_STATUS)
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                s.commit(PendingIntent.getBroadcast(ctx, 3, cb, flags).intentSender)
            }
            changed()
            "ok"
        } catch (e: Exception) {
            val m = e.message ?: e.javaClass.simpleName
            p.edit().putString("error", "не получилось поставить: $m").apply()
            changed()
            m
        }
    }

    /**
     * Запасной путь — обычный системный установщик, как у файла из загрузок. На случай,
     * если тихая установка на этом телефоне не проходит.
     */
    fun openInstaller(a: Activity): String {
        val f = ready(a) ?: return "обновление ещё не скачано"
        val uri = FileProvider.getUriForFile(a, "${a.packageName}.update", f)
        val i = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        a.runOnUiThread { try { a.startActivity(i) } catch (_: Exception) {} }
        return "ok"
    }

    /** Ответ установщика системы. */
    fun onStatus(ctx: Context, intent: Intent) {
        val p = prefs(ctx)
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Система хочет подтверждения (первый раз — разрешение ставить приложения из этого источника).
                @Suppress("DEPRECATION")
                val confirm = (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else intent.getParcelableExtra(Intent.EXTRA_INTENT)) ?: return
                p.edit().putString("wait", "confirm").apply()
                if (MainActivity.visible) {
                    try { ctx.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
                } else {
                    notify(ctx, "Обновление готово", "Версия ${p.getString("readyVersion", "")} ждёт подтверждения установки", true)
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {}
            PackageInstaller.STATUS_FAILURE_ABORTED -> p.edit().putString("wait", "confirm").apply()
            else -> {
                val m = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "установка не прошла"
                p.edit().putString("error", "не получилось поставить: $m").apply()
            }
        }
        changed()
    }

    /** Новая версия только что встала поверх старой. */
    fun onReplaced(ctx: Context) {
        val p = prefs(ctx)
        val v = p.getString("readyVersion", "") ?: ""
        if (p.getLong("readyCode", 0) == installedCode(ctx)) {
            p.edit().putString("updatedVersion", v).putString("updatedNotes", p.getString("readyNotes", "")).apply()
        }
        val reopen = p.getBoolean("reopen", false)
        p.edit().remove("reopen").apply()
        dir(ctx).listFiles()?.forEach { it.delete() }
        p.edit().remove("readyVersion").remove("readyCode").remove("readyNotes").remove("readySha")
            .remove("readyFile").remove("wait").remove("tries").putString("error", "").apply()
        // Установка закрыла открытое приложение — вернуться одним касанием.
        if (reopen) notify(ctx, "Фигурное катание обновлено до ${installedName(ctx)}", p.getString("updatedNotes", "") ?: "", false)
        schedule(ctx)
    }

    @SuppressLint("MissingPermission")
    private fun notify(ctx: Context, title: String, text: String, install: Boolean) {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(CHANNEL, "Обновления", NotificationManager.IMPORTANCE_DEFAULT)
            ctx.getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
        val open = Intent(ctx, MainActivity::class.java).putExtra(EXTRA_INSTALL, install)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pi = PendingIntent.getActivity(ctx, NOTE_ID, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_notify)
            .setColor(0xFF1C5C9C.toInt())
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        try { NotificationManagerCompat.from(ctx).notify(NOTE_ID, n) } catch (_: SecurityException) {}
    }

    fun clearNotice(ctx: Context) = NotificationManagerCompat.from(ctx).cancel(NOTE_ID)

    // ---------- расписание проверок ----------

    fun schedule(ctx: Context) {
        val js = ctx.getSystemService(JobScheduler::class.java) ?: return
        if (js.getPendingJob(JOB_ID) != null) return
        val job = JobInfo.Builder(JOB_ID, ComponentName(ctx, UpdateJob::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPeriodic(3600_000L, 15 * 60_000L)
            .setPersisted(true)
            .build()
        try { js.schedule(job) } catch (_: Exception) {}
    }

    /** Для интерфейса: честное состояние обновлений. */
    fun statusJson(ctx: Context): String {
        val p = prefs(ctx)
        val o = JSONObject()
            .put("enabled", true)
            .put("current", installedName(ctx))
        if (checking) o.put("checking", true)
        p.getLong("checkedAt", 0).takeIf { it > 0 }?.let { o.put("checkedAt", it) }
        p.getString("error", "")?.takeIf { it.isNotEmpty() }?.let { o.put("error", it) }
        p.getString("dl", "")?.takeIf { it.isNotEmpty() }?.let { o.put("downloading", it) }
        if (ready(ctx) != null) {
            o.put("ready", JSONObject().put("version", p.getString("readyVersion", "")).put("notes", p.getString("readyNotes", "")))
            o.put("wait", p.getString("wait", "").takeIf { !it.isNullOrEmpty() } ?: "leave")
            if (p.getInt("tries", 0) >= 3) o.put("stuck", true)
        }
        p.getString("updatedVersion", "")?.takeIf { it.isNotEmpty() }?.let {
            o.put("updated", JSONObject().put("version", it).put("notes", p.getString("updatedNotes", "")))
        }
        return o.toString()
    }

    fun check(ctx: Context) { thread(name = "update") { run(ctx.applicationContext, install = false) } }
}

class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Updater.ACTION_STATUS) Updater.onStatus(context, intent)
    }
}

/** Новая версия встала: запомнить, что изменилось, и вернуть проверки. */
class ReplacedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_MY_PACKAGE_REPLACED -> Updater.onReplaced(context)
            Intent.ACTION_BOOT_COMPLETED -> Updater.schedule(context)
        }
    }
}

class UpdateJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        thread(name = "update-job") {
            try { Updater.run(applicationContext, install = true) } finally { jobFinished(params, false) }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = true
}

/** Своё имя класса — чтобы не спорить в манифесте с провайдерами файлов из плагинов. */
class UpdateFiles : FileProvider()
