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

/**
 * at — показать; hold — до этого момента не смахивается (0 — смахивается сразу); end — убрать.
 * title — заголовок; body — одна строка свёрнутого вида; lines — строки развёрнутого (InboxStyle),
 * пусто — развёрнутый повторяет body. group — турнир: его уведомления в одной стопке под groupTitle.
 * reminder — выход спортсмена (напоминание), иначе начало старта (событие).
 */
class Entry(
    val key: String,
    val at: Long,
    val hold: Long,
    val end: Long,
    val title: String,
    val body: String,
    val lines: List<String> = emptyList(),
    val group: String = "",
    val groupTitle: String = "",
    val reminder: Boolean = false,
) {
    val id: Int get() = key.hashCode() and 0x7fffffff

    /** Тот же текст — обновлять висящее незачем. */
    fun sameText(o: Entry) = title == o.title && body == o.body && lines == o.lines
}

/**
 * Уведомления о стартах.
 *  • приходят в назначенное время (точный будильник);
 *  • закреплены до hold (старт — до конца, спортсмен — пока не откатал): «ongoing», а если
 *    смахнули — возвращаются без звука; после hold — обычные, смахиваются; убираются сами в end;
 *  • не исчезают при открытии приложения и нажатии (автоудаления по нажатию нет);
 *  • канал без значка на иконке — цифры нет;
 *  • в строке состояния One UI по умолчанию только три значка «последних» уведомлений, а порядок —
 *    по времени уведомления. Закреплённое поэтому раз в несколько минут обновляется на месте
 *    (без звука) — иначе любое свежее сообщение вытесняет его значок, и видно его только
 *    на экране блокировки, где значков без ограничения;
 *  • вид: свёрнутый — заголовок и одна строка, развёрнутый — построчно (InboxStyle);
 *  • уведомления одного турнира складываются в стопку: при двух и больше висящих — сводное;
 *  • полоса «Live Notifications» в шторке One UI — для музыки и живых карточек, обычному
 *    уведомлению туда хода нет (и не просимся): его место — первое среди обычных.
 * Расписание хранится здесь же и поднимается после перезагрузки и обновления.
 */
object Alerts {
    const val CHANNEL = "alerts"
    private const val PREFS = "alerts"
    private const val FIRE = "ru.furya.starty.alerts.FIRE"
    private const val DELETED = "ru.furya.starty.alerts.DELETED"
    private const val RELEASE = "ru.furya.starty.alerts.RELEASE"
    private const val TICK = "ru.furya.starty.alerts.TICK"
    private const val TICK_EVERY = 5 * 60_000L
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
                val end = o.getLong("end")
                val ls = o.optJSONArray("lines")
                val lines = if (ls == null) emptyList() else List(ls.length()) { ls.optString(it) }
                val e = Entry(
                    o.getString("key"), o.getLong("at"), o.optLong("hold", end), end, o.optString("title"), o.optString("body"),
                    lines, o.optString("group"), o.optString("groupTitle"), o.optBoolean("reminder"),
                )
                out[e.key] = e
            }
        } catch (_: Exception) {}
        return out
    }

    private fun save(c: Context, m: Map<String, Entry>) {
        val a = JSONArray()
        for (e in m.values) {
            a.put(
                JSONObject().put("key", e.key).put("at", e.at).put("hold", e.hold).put("end", e.end).put("title", e.title).put("body", e.body)
                    .put("lines", JSONArray(e.lines)).put("group", e.group).put("groupTitle", e.groupTitle).put("reminder", e.reminder)
            )
        }
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
        ch.description = "Начало старта и выход спортсменов"
        ch.setShowBadge(false)
        m.createNotificationChannel(ch)
    }

    // ---------------------------------------------------------------- будильники

    private fun intent(c: Context, action: String, id: Int?): PendingIntent {
        val i = Intent(c, AlertReceiver::class.java).setAction(action).setData(Uri.parse("alert://${id ?: 0}"))
        return PendingIntent.getBroadcast(c, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun alarm(c: Context, at: Long, pi: PendingIntent, exact: Boolean = true) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        try {
            if (!exact || (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms())) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    private fun cancel(c: Context, pi: PendingIntent) {
        (c.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(pi)
    }

    private fun setAlarm(c: Context, e: Entry) = alarm(c, e.at, intent(c, FIRE, e.id))

    /** Когда закрепление кончается раньше конца — снять его в срок. */
    private fun setRelease(c: Context, e: Entry) {
        if (e.hold in (System.currentTimeMillis() + 1) until e.end) alarm(c, e.hold, intent(c, RELEASE, e.id))
    }

    private fun cancelAlarm(c: Context, e: Entry) {
        cancel(c, intent(c, FIRE, e.id))
        cancel(c, intent(c, RELEASE, e.id))
    }

    /** Освежать закреплённые, пока такие висят; одно напоминание на все. */
    private fun scheduleTick(c: Context) {
        val now = System.currentTimeMillis()
        val f = fired(c)
        val pinned = load(c).values.any { it.key in f && it.hold > now && it.end > now }
        val pi = intent(c, TICK, null)
        if (pinned) alarm(c, now + TICK_EVERY, pi, exact = false) else cancel(c, pi)
    }

    // ---------------------------------------------------------------- показ

    private fun active(c: Context, e: Entry): Boolean =
        nm(c).activeNotifications.any { it.id == e.id && it.packageName == c.packageName }

    /**
     * quiet — без звука и всплывания (возврат смахнутого, после перезагрузки). Обновление
     * висящего и так тихое — setOnlyAlertOnce. setSilent здесь не годится: он кладёт уведомление
     * в общую группу «silent», и такое оболочка может не показать значком в строке состояния.
     */
    private fun icon(c: Context): Int =
        c.resources.getIdentifier("ic_notify", "drawable", c.packageName).takeIf { it != 0 } ?: c.applicationInfo.icon

    /** InboxStyle показывает не больше семи строк: лишнее — «и ещё N» в сводке стиля. */
    private const val MAX_LINES = 7

    private fun groupKey(e: Entry) = if (e.group.isEmpty()) "starty.${e.id}" else "starty.t.${e.group}"

    private fun post(c: Context, e: Entry, quiet: Boolean) {
        val now = System.currentTimeMillis()
        if (e.end <= now) return
        val pinned = e.hold > now
        ensureChannel(c)
        val open = c.packageManager.getLaunchIntentForPackage(c.packageName)?.let {
            PendingIntent.getActivity(c, e.id, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val del = PendingIntent.getBroadcast(
            c, 0,
            Intent(c, AlertReceiver::class.java).setAction(DELETED).setData(Uri.parse("alert://${e.id}")),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val style: NotificationCompat.Style = if (e.lines.size > 1) {
            val inbox = NotificationCompat.InboxStyle()
            val fit = if (e.lines.size > MAX_LINES) MAX_LINES - 1 else e.lines.size
            for (l in e.lines.take(fit)) inbox.addLine(l)
            if (fit < e.lines.size) inbox.setSummaryText("и ещё ${e.lines.size - fit}")
            inbox
        } else {
            NotificationCompat.BigTextStyle().bigText(e.lines.firstOrNull() ?: e.body)
        }
        val b = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(icon(c))
            .setContentTitle(e.title)
            .setContentText(e.body)
            .setStyle(style)
            .setCategory(if (e.reminder) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(pinned)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            // время уже в заголовке; своё время уведомления — момент показа, он и ставит его
            // среди свежих (см. выше про строку состояния)
            .setShowWhen(false)
            .setTimeoutAfter(e.end - now)
        if (pinned) b.setDeleteIntent(del)
        // стопка турнира; внутри — по времени. Тихое звучит только «сводкой», а сводное
        // само не звучит никогда — значит, тихое молчит
        b.setGroup(groupKey(e))
            .setSortKey(String.format(java.util.Locale.ROOT, "%015d", e.at))
            .setGroupAlertBehavior(if (quiet) NotificationCompat.GROUP_ALERT_SUMMARY else NotificationCompat.GROUP_ALERT_CHILDREN)
        if (open != null) b.setContentIntent(open)
        try {
            NotificationManagerCompat.from(c).notify(e.id, b.build())
        } catch (_: SecurityException) {
            // уведомления запрещены — молча: расписание остаётся
        }
        regroup(c, e.group, posted = e.id)
    }

    private fun summaryId(group: String) = "group:$group".hashCode() and 0x7fffffff

    /**
     * Сводное уведомление турнира: есть, пока висят два и больше его уведомлений, иначе снято
     * (одно показывается само по себе). Само не звучит; закреплено, если закреплено хоть одно.
     * Показ и снятие доходят до системы не сразу: только что показанное ([posted]) и снятые
     * ([gone]) учитываются здесь, а не по списку висящих.
     */
    private fun regroup(c: Context, group: String, posted: Int? = null, gone: Set<Int> = emptySet()) {
        if (group.isEmpty()) return
        val now = System.currentTimeMillis()
        val sid = summaryId(group)
        val shown = try {
            nm(c).activeNotifications.filter { it.packageName == c.packageName }.map { it.id }.toMutableSet()
        } catch (_: Exception) {
            return
        }
        val hadSummary = sid in shown
        if (posted != null) shown.add(posted)
        shown.removeAll(gone)
        val members = load(c).values.filter { it.group == group && it.end > now && it.id in shown }.sortedBy { it.at }
        if (members.size < 2) {
            if (hadSummary) NotificationManagerCompat.from(c).cancel(sid)
            return
        }
        val title = members.first().groupTitle
        val inbox = NotificationCompat.InboxStyle().setBigContentTitle(title)
        for (m in members.take(MAX_LINES)) inbox.addLine(m.title)
        val b = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(icon(c))
            .setContentTitle(title)
            .setContentText(members.first().title)
            .setStyle(inbox)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setGroup(groupKey(members.first()))
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setOngoing(members.any { it.hold > now })
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setTimeoutAfter(members.maxOf { it.end } - now)
        c.packageManager.getLaunchIntentForPackage(c.packageName)?.let {
            b.setContentIntent(PendingIntent.getActivity(c, sid, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        }
        try {
            NotificationManagerCompat.from(c).notify(sid, b.build())
        } catch (_: SecurityException) {}
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
        val oldFired = fired
        // сначала новое расписание — чтобы возврат смахнутого не поднял убранное
        save(c, next)
        val touched = HashSet<String>()
        val gone = HashSet<Int>()
        for (o in old.values) {
            if (o.key in next) continue
            cancelAlarm(c, o)
            NotificationManagerCompat.from(c).cancel(o.id)
            touched.add(o.group)
            gone.add(o.id)
        }
        saveFired(c, fired.filter { it in next }.toSet())
        for (e in next.values) {
            val p = old[e.key]
            if (e.at > now) {
                setAlarm(c, e)
                setRelease(c, e)
            } else if (e.key in oldFired) {
                if (p == null || !p.sameText(e) || (p.hold > now) != (e.hold > now)) {
                    // текст поменялся или спортсмен уже откатал, пока уведомление висит — обновить тихо
                    if (active(c, e)) post(c, e, quiet = true)
                }
                cancel(c, intent(c, RELEASE, e.id))
                setRelease(c, e)
            }
        }
        for (g in touched) regroup(c, g, gone = gone)
        scheduleTick(c)
    }

    @Synchronized
    fun clear(c: Context) {
        val old = load(c)
        save(c, emptyMap())
        saveFired(c, emptySet())
        for (o in old.values) {
            cancelAlarm(c, o)
            NotificationManagerCompat.from(c).cancel(o.id)
            if (o.group.isNotEmpty()) NotificationManagerCompat.from(c).cancel(summaryId(o.group))
        }
        scheduleTick(c)
    }

    // ---------------------------------------------------------------- из будильника и системы

    @Synchronized
    fun fire(c: Context, id: Int) {
        val e = load(c).values.firstOrNull { it.id == id } ?: return
        val f = fired(c)
        if (e.key in f || e.end <= System.currentTimeMillis()) return
        f.add(e.key)
        saveFired(c, f)
        post(c, e, quiet = false)
        scheduleTick(c)
    }

    /** Смахнули закреплённое — вернуть. Убранное нами (нет в расписании) и откреплённое не возвращаем. */
    @Synchronized
    fun deleted(c: Context, id: Int) {
        val e = load(c).values.firstOrNull { it.id == id } ?: return
        if (e.key !in fired(c)) return
        val now = System.currentTimeMillis()
        if (e.end - now <= GRACE || e.hold - now <= GRACE) return
        post(c, e, quiet = true)
    }

    /** Закрепление кончилось (спортсмен откатал) — висящее становится обычным, смахиваемым. */
    @Synchronized
    fun release(c: Context, id: Int) {
        val e = load(c).values.firstOrNull { it.id == id } ?: return
        if (e.key in fired(c) && active(c, e)) post(c, e, quiet = true)
        scheduleTick(c)
    }

    /** Освежить закреплённые висящие — держать их значок в строке состояния. */
    @Synchronized
    fun tick(c: Context) {
        val now = System.currentTimeMillis()
        val f = fired(c)
        for (e in load(c).values) {
            if (e.key in f && e.hold > now && e.end > now && active(c, e)) post(c, e, quiet = true)
        }
        scheduleTick(c)
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
                setRelease(c, e)
            } else if (e.key !in f) {
                f.add(e.key)
                post(c, e, quiet = false)
                setRelease(c, e)
            } else if (!active(c, e) && e.hold > now) {
                // перезагрузка стёрла закреплённое — вернуть
                post(c, e, quiet = true)
                setRelease(c, e)
            }
        }
        save(c, keep)
        saveFired(c, f.filter { it in keep }.toSet())
        scheduleTick(c)
    }
}

class AlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.data?.host?.toIntOrNull() ?: return
        when (intent.action) {
            "ru.furya.starty.alerts.FIRE" -> Alerts.fire(context, id)
            "ru.furya.starty.alerts.DELETED" -> Alerts.deleted(context, id)
            "ru.furya.starty.alerts.RELEASE" -> Alerts.release(context, id)
            "ru.furya.starty.alerts.TICK" -> Alerts.tick(context)
        }
    }
}

class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Alerts.restore(context)
    }
}
