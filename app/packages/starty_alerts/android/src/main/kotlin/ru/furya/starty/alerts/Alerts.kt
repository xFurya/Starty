package ru.furya.starty.alerts

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject

class Entry(val key: String, val at: Long, val end: Long, val title: String, val body: String) {
    val id: Int get() = key.hashCode() and 0x7fffffff
}

/**
 * Уведомления о стартах.
 *  • приходят в назначенное время (точный будильник);
 *  • висят до конца старта: «ongoing», автоудаление по концу, а если смахнули — возвращаются;
 *  • не исчезают при открытии приложения и нажатии (автоудаления по нажатию нет);
 *  • канал без значка на иконке — цифры нет.
 * Расписание хранится здесь же и поднимается после перезагрузки и обновления.
 */
object Alerts {
    const val CHANNEL = "alerts"
    private const val PREFS = "alerts"
    private const val FIRE = "ru.furya.starty.alerts.FIRE"
    private const val DELETED = "ru.furya.starty.alerts.DELETED"
    private const val GRACE = 3_000L // удаление по таймеру приходит чуть раньше конца

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private fun nm(c: Context) = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    // ---------------------------------------------------------------- хранение

    private fun load(c: Context): MutableMap<String, Entry> {
        val out = LinkedHashMap<String, Entry>()
        try {
            val a = JSONArray(prefs(c).getString("plan", "[]"))
            for (i in 0 until a.length()) {
                val o = a.getJSONObject(i)
                val e = Entry(o.getString("key"), o.getLong("at"), o.getLong("end"), o.optString("title"), o.optString("body"))
                out[e.key] = e
            }
        } catch (_: Exception) {}
        return out
    }

    private fun save(c: Context, m: Map<String, Entry>) {
        val a = JSONArray()
        for (e in m.values) a.put(JSONObject().put("key", e.key).put("at", e.at).put("end", e.end).put("title", e.title).put("body", e.body))
        prefs(c).edit().putString("plan", a.toString()).apply()
    }

    private fun fired(c: Context): MutableSet<String> {
        val s = HashSet<String>()
        try {
            val a = JSONArray(prefs(c).getString("fired", "[]"))
            for (i in 0 until a.length()) s.add(a.getString(i))
        } catch (_: Exception) {}
        return s
    }

    private fun saveFired(c: Context, s: Set<String>) {
        prefs(c).edit().putString("fired", JSONArray(s.toList()).toString()).apply()
    }

    // ---------------------------------------------------------------- канал

    fun ensureChannel(c: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val m = nm(c)
        // каналы старых версий (со значком на иконке) убираем
        for (old in listOf("starts", "skaters")) m.deleteNotificationChannel(old)
        if (m.getNotificationChannel(CHANNEL) != null) return
        val ch = NotificationChannel(CHANNEL, "Старты", NotificationManager.IMPORTANCE_HIGH)
        ch.description = "Начало старта и выход наших"
        ch.setShowBadge(false)
        m.createNotificationChannel(ch)
    }

    // ---------------------------------------------------------------- будильники

    private fun alarmIntent(c: Context, e: Entry): PendingIntent {
        val i = Intent(c, AlertReceiver::class.java).setAction(FIRE).setData(Uri.parse("alert://${e.id}"))
        return PendingIntent.getBroadcast(c, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun setAlarm(c: Context, e: Entry) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = alarmIntent(c, e)
        try {
            if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, e.at, pi)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, e.at, pi)
            }
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, e.at, pi)
        }
    }

    private fun cancelAlarm(c: Context, e: Entry) {
        (c.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(alarmIntent(c, e))
    }

    // ---------------------------------------------------------------- показ

    private fun active(c: Context, e: Entry): Boolean =
        nm(c).activeNotifications.any { it.id == e.id && it.packageName == c.packageName }

    private fun post(c: Context, e: Entry, silent: Boolean) {
        val now = System.currentTimeMillis()
        if (e.end <= now) return
        ensureChannel(c)
        val icon = c.resources.getIdentifier("ic_notify", "drawable", c.packageName).takeIf { it != 0 } ?: c.applicationInfo.icon
        val open = c.packageManager.getLaunchIntentForPackage(c.packageName)?.let {
            PendingIntent.getActivity(c, e.id, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val del = PendingIntent.getBroadcast(
            c, 0,
            Intent(c, AlertReceiver::class.java).setAction(DELETED).setData(Uri.parse("alert://${e.id}")),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val b = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(icon)
            .setContentTitle(e.title)
            .setContentText(e.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(e.body))
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(silent)
            .setShowWhen(true)
            .setWhen(e.at)
            .setTimeoutAfter(e.end - now)
            .setDeleteIntent(del)
        if (open != null) b.setContentIntent(open)
        try {
            NotificationManagerCompat.from(c).notify(e.id, b.build())
        } catch (_: SecurityException) {
            // уведомления запрещены — молча: расписание остаётся
        }
    }

    // ---------------------------------------------------------------- вызовы из Dart

    @Synchronized
    fun sync(c: Context, list: List<Entry>) {
        ensureChannel(c)
        val now = System.currentTimeMillis()
        val old = load(c)
        val fired = fired(c)
        val next = LinkedHashMap<String, Entry>()
        for (e in list) if (e.end > now) next[e.key] = e
        // сначала новое расписание — чтобы возврат смахнутого не поднял убранное
        save(c, next)
        for (o in old.values) {
            if (o.key in next) continue
            cancelAlarm(c, o)
            NotificationManagerCompat.from(c).cancel(o.id)
        }
        saveFired(c, fired.filter { it in next }.toSet())
        for (e in next.values) {
            val p = old[e.key]
            if (e.at > now) {
                setAlarm(c, e)
            } else if (e.key in fired && (p == null || p.title != e.title || p.body != e.body)) {
                // время или текст поменялись, пока уведомление висит — обновить без звука
                if (active(c, e)) post(c, e, silent = true)
            }
        }
    }

    @Synchronized
    fun clear(c: Context) {
        val old = load(c)
        save(c, emptyMap())
        saveFired(c, emptySet())
        for (o in old.values) {
            cancelAlarm(c, o)
            NotificationManagerCompat.from(c).cancel(o.id)
        }
    }

    // ---------------------------------------------------------------- из будильника и системы

    @Synchronized
    fun fire(c: Context, id: Int) {
        val e = load(c).values.firstOrNull { it.id == id } ?: return
        val f = fired(c)
        if (e.key in f || e.end <= System.currentTimeMillis()) return
        f.add(e.key)
        saveFired(c, f)
        post(c, e, silent = false)
    }

    /** Смахнули — вернуть, пока старт не кончился. Убранное нами (нет в расписании) не возвращаем. */
    @Synchronized
    fun deleted(c: Context, id: Int) {
        val e = load(c).values.firstOrNull { it.id == id } ?: return
        if (e.key !in fired(c)) return
        if (e.end - System.currentTimeMillis() <= GRACE) return
        post(c, e, silent = true)
    }

    /** После перезагрузки, обновления приложения, смены времени: будильники заново, пропущенное — показать. */
    @Synchronized
    fun restore(c: Context) {
        ensureChannel(c)
        val now = System.currentTimeMillis()
        val plan = load(c)
        val f = fired(c)
        val keep = LinkedHashMap<String, Entry>()
        for (e in plan.values) {
            if (e.end <= now) continue
            keep[e.key] = e
            if (e.at > now) {
                setAlarm(c, e)
            } else if (e.key !in f) {
                f.add(e.key)
                post(c, e, silent = false)
            } else if (!active(c, e)) {
                // перезагрузка стёрла показанное — вернуть
                post(c, e, silent = true)
            }
        }
        save(c, keep)
        saveFired(c, f.filter { it in keep }.toSet())
    }
}

class AlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.data?.host?.toIntOrNull() ?: return
        when (intent.action) {
            "ru.furya.starty.alerts.FIRE" -> Alerts.fire(context, id)
            "ru.furya.starty.alerts.DELETED" -> Alerts.deleted(context, id)
        }
    }
}

class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Alerts.restore(context)
    }
}
