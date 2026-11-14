package ru.furya.starty.alerts

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * at — показать; hold — до этого момента не смахивается (0 — смахивается сразу); end — убрать.
 * title — заголовок; body — одна строка свёрнутого вида; lines — строки развёрнутого (InboxStyle),
 * пусто — развёрнутый повторяет body. group — турнир: его уведомления в одной стопке под groupTitle.
 * reminder — выход спортсмена (напоминание), иначе начало старта (событие).
 * liveAt — начало старта (0 — нет): с него заголовок — liveTitle, где часть liveMark («🔴 ИДЁТ») —
 * цветом liveColor (liveColorDark в тёмной теме), как метка на карточке старта в приложении.
 * start — старт, к которому относится уведомление (по нему файл состояния говорит «закончился» и «затянулся»).
 * late — время показа прошло, а показано не было: показать, пока сейчас раньше late.
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
    val liveAt: Long = 0,
    val liveTitle: String = "",
    val liveMark: String = "",
    val liveColor: Int = 0,
    val liveColorDark: Int = 0,
    val start: String = "",
    val late: Long = end,
    /** Данные карточки (JSON, см. Reminders.startCard в приложении); пусто — обычное уведомление. */
    val card: String = "",
) {
    val id: Int get() = key.hashCode() and 0x7fffffff

    /** Тот же, но убрать позже: закреплённое до конца остаётся закреплённым до нового конца. */
    fun until(newEnd: Long) = Entry(
        key, at, if (hold >= end) newEnd else hold, newEnd, title, body, lines, group, groupTitle, reminder,
        liveAt, liveTitle, liveMark, liveColor, liveColorDark, start, late, card,
    )

    /** Старт уже идёт — в заголовке статус вместо времени начала. */
    fun isLive(now: Long) = liveTitle.isNotEmpty() && liveAt in 1..now

    fun titleAt(now: Long) = if (isLive(now)) liveTitle else title

    /** Тот же текст на момент now — обновлять висящее незачем. */
    fun sameText(o: Entry, now: Long) =
        titleAt(now) == o.titleAt(now) && body == o.body && lines == o.lines && card == o.card
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
 *  • вид: свёрнутый — заголовок и одна строка, развёрнутый — построчно (InboxStyle); у старта с
 *    данными карточки (card) — своя раскладка: вид и программа, метка «через 14:32» или «ИДЁТ»,
 *    время начала, в развёрнутом — отслеживаемые и трансляция (alert_card.xml);
 *  • в начало старта висящее уведомление о нём тихо меняет время в заголовке на статус «🔴 ИДЁТ»;
 *  • уведомления одного турнира складываются в стопку: при двух и больше висящих — сводное;
 *  • время показа прошло, а показано не было (старт добавили или сдвинули раньше, уведомления включили
 *    посреди старта) — показывается сразу, если ещё не поздно (late); старт перенесли на потом —
 *    показанное снимается и придёт заново в новое время;
 *  • пока висит уведомление о старте, раз в пару минут спрашиваем у сервера маленький файл
 *    состояния (now.json): старт закончился — его уведомления снимаются сразу, а не в конец по расписанию;
 *    затянулся (табло говорит, что идёт) — не снимаются в конец по расписанию;
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
    private const val LIVE = "ru.furya.starty.alerts.LIVE"
    private const val WATCH = "ru.furya.starty.alerts.WATCH"
    private const val TICK_EVERY = 5 * 60_000L
    private const val GRACE = 3_000L // удаление по таймеру приходит чуть раньше конца
    private const val WATCH_EVERY = 2 * 60_000L
    // показанное уведомление о том, что сдвинулось на потом больше чем на столько, — снять и показать заново в срок;
    // меньший сдвиг (время выхода спортсмена уточнилось) — только поправить текст висящего
    private const val REFIRE = 10 * 60_000L
    // затянувшийся старт: сколько после расписания ещё верим табло (как Start.overrunLimit) и на сколько продлеваем за раз
    private const val OVERRUN = 3 * 3_600_000L
    private const val RUN_AHEAD = 20 * 60_000L
    private const val RUN_MARGIN = 10 * 60_000L

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
                    o.optLong("liveAt"), o.optString("liveTitle"), o.optString("liveMark"), o.optInt("liveColor"), o.optInt("liveColorDark"),
                    o.optString("start"), o.optLong("late", end), o.optString("card"),
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
                    .put("liveAt", e.liveAt).put("liveTitle", e.liveTitle).put("liveMark", e.liveMark)
                    .put("liveColor", e.liveColor).put("liveColorDark", e.liveColorDark)
                    .put("start", e.start).put("late", e.late).put("card", e.card)
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

    /** Закончившиеся старты (по серверу или по данным приложения) → до какого момента помнить. */
    private fun done(c: Context, now: Long): MutableMap<String, Long> {
        val m = HashMap<String, Long>()
        try {
            val o = JSONObject(prefs(c).getString("done", "{}") ?: "{}")
            for (k in o.keys()) {
                val until = o.optLong(k)
                if (until > now) m[k] = until
            }
        } catch (_: Exception) {}
        return m
    }

    private fun saveDone(c: Context, m: Map<String, Long>) {
        val o = JSONObject()
        for ((k, v) in m) o.put(k, v)
        prefs(c).edit().putString("done", o.toString()).apply()
    }

    // ---------------------------------------------------------------- работа в фоне

    /**
     * 0 — без ограничений; 1 — экономия энергии (так у всех приложений по умолчанию): точные
     * будильники приходят, а проверка конца старта и фоновое обновление могут опаздывать;
     * 2 — работа в фоне запрещена (в настройках батареи приложения): уведомления могут не прийти.
     */
    fun background(c: Context): Int {
        if (Build.VERSION.SDK_INT >= 28) {
            val am = c.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            if (am.isBackgroundRestricted) return 2
        }
        val pm = c.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        return if (pm.isIgnoringBatteryOptimizations(c.packageName)) 0 else 1
    }

    /** Снять ограничение: системный вопрос, а если работа в фоне запрещена — сведения о приложении (там батарея). */
    fun allowBackground(c: Context) {
        val details = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${c.packageName}"))
        val ask = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${c.packageName}"))
        val list = Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        val order = if (background(c) == 2) listOf(details) else listOf(ask, list, details)
        for (i in order) {
            try {
                c.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Exception) {}
        }
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

    /** Старт начнётся, пока уведомление висит, — в его начало сменить время на статус. */
    private fun setLive(c: Context, e: Entry) {
        val pi = intent(c, LIVE, e.id)
        if (e.liveTitle.isNotEmpty() && e.liveAt in (System.currentTimeMillis() + 1) until e.end) alarm(c, e.liveAt, pi) else cancel(c, pi)
    }

    private fun cancelAlarm(c: Context, e: Entry) {
        cancel(c, intent(c, FIRE, e.id))
        cancel(c, intent(c, RELEASE, e.id))
        cancel(c, intent(c, LIVE, e.id))
    }

    /**
     * Спрашивать файл состояния, пока висит уведомление о старте (или о выходе спортсмена в нём):
     * одно напоминание на все. Не точное — система вправе сдвинуть его в экономии энергии.
     */
    private fun scheduleWatch(c: Context) {
        val now = System.currentTimeMillis()
        val url = prefs(c).getString("watch", "") ?: ""
        val f = fired(c)
        // по списку показанных не проверяем: только что показанное доходит до системы не сразу
        val need = url.isNotEmpty() && NotificationManagerCompat.from(c).areNotificationsEnabled() &&
            load(c).values.any { it.start.isNotEmpty() && it.key in f && it.end > now }
        val pi = intent(c, WATCH, null)
        if (need) alarm(c, now + WATCH_EVERY, pi, exact = false) else cancel(c, pi)
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

    private fun active(c: Context, e: Entry): Boolean = try {
        nm(c).activeNotifications.any { it.id == e.id && it.packageName == c.packageName }
    } catch (_: Exception) {
        false
    }

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

    private fun night(c: Context) =
        (c.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

    /**
     * Заголовок на момент now. У идущего старта статус («🔴 ИДЁТ») — красным и жирным, как метка
     * на карточке старта. Цвет текста заголовка система вправе снять
     * (так и вышло на телефоне владельца), поэтому на цвет текста не полагаемся: красный держит
     * сама точка-эмодзи, а слово — жирное. От устройства и оболочки ничего не зависит.
     */
    private fun shownTitle(c: Context, e: Entry, now: Long): CharSequence {
        val t = e.titleAt(now)
        val i = if (e.isLive(now) && e.liveMark.isNotEmpty()) t.lastIndexOf(e.liveMark) else -1
        if (i < 0) return t
        val end = i + e.liveMark.length
        val s = SpannableString(t)
        val color = if (night(c)) e.liveColorDark else e.liveColor
        if (color != 0) s.setSpan(ForegroundColorSpan(color), i, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        s.setSpan(StyleSpan(Typeface.BOLD), i, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        return s
    }

    /**
     * Карточка уведомления о старте: свёрнутый и развёрнутый вид по данным e.card. Слева — вид и
     * программа над турниром, посередине — метка: до начала «через 14:32» (отсчёт идёт сам, без
     * обновлений), с начала — «ИДЁТ»; справа — время начала. В развёрнутом — отслеживаемые со
     * временем выхода и трансляция. null — данных нет или их не разобрать: уведомление обычное.
     */
    private fun cardViews(c: Context, e: Entry, now: Long): Pair<RemoteViews, RemoteViews>? {
        if (e.card.isEmpty() || e.reminder) return null
        return try {
            val o = JSONObject(e.card)
            val what = listOf(o.optString("what"), o.optString("seg")).filter { it.isNotEmpty() }.joinToString(", ")
            if (what.isEmpty()) return null
            val t0 = o.optLong("t0")
            val live = e.isLive(now) || t0 in 1..now
            fun fill(v: RemoteViews) {
                v.setTextViewText(R.id.alert_what, what)
                v.setTextViewText(R.id.alert_tour, o.optString("tour"))
                v.setTextViewText(R.id.alert_time, o.optString("time"))
                v.setViewVisibility(R.id.alert_soon, if (live || t0 <= 0) View.GONE else View.VISIBLE)
                v.setViewVisibility(R.id.alert_live, if (live) View.VISIBLE else View.GONE)
                if (!live && t0 > 0) {
                    v.setChronometerCountDown(R.id.alert_count, true)
                    v.setChronometer(R.id.alert_count, SystemClock.elapsedRealtime() + (t0 - now), null, true)
                }
            }
            val small = RemoteViews(c.packageName, R.layout.alert_card)
            val big = RemoteViews(c.packageName, R.layout.alert_card_big)
            fill(small)
            fill(big)
            val rows = o.optJSONArray("rows")
            val ids = arrayOf(
                intArrayOf(R.id.alert_row1, R.id.alert_row1_time, R.id.alert_row1_name),
                intArrayOf(R.id.alert_row2, R.id.alert_row2_time, R.id.alert_row2_name),
                intArrayOf(R.id.alert_row3, R.id.alert_row3_time, R.id.alert_row3_name),
                intArrayOf(R.id.alert_row4, R.id.alert_row4_time, R.id.alert_row4_name),
            )
            for (i in ids.indices) {
                val r = rows?.optJSONArray(i)
                if (r == null || r.optString(1).isEmpty()) {
                    big.setViewVisibility(ids[i][0], View.GONE)
                    continue
                }
                big.setViewVisibility(ids[i][0], View.VISIBLE)
                big.setTextViewText(ids[i][1], r.optString(0))
                big.setTextViewText(ids[i][2], r.optString(1))
            }
            val more = o.optInt("more")
            big.setViewVisibility(R.id.alert_more, if (more > 0) View.VISIBLE else View.GONE)
            if (more > 0) big.setTextViewText(R.id.alert_more, "и ещё $more")
            val watch = o.optString("watch")
            big.setViewVisibility(R.id.alert_watch, if (watch.isNotEmpty()) View.VISIBLE else View.GONE)
            if (watch.isNotEmpty()) big.setTextViewText(R.id.alert_watch, "Трансляция: $watch")
            small to big
        } catch (_: Exception) {
            null
        }
    }

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
        // карточка — своя раскладка в рамке системы; заголовок и строка остаются для часов,
        // экрана блокировки со скрытым содержимым и сводки стопки
        val card = cardViews(c, e, now)
        val b = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(icon(c))
            .setContentTitle(shownTitle(c, e, now))
            .setContentText(e.body)
            .setStyle(if (card != null) NotificationCompat.DecoratedCustomViewStyle() else style)
            .setCategory(if (e.reminder) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(pinned)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            // время уже в заголовке (у идущего старта — статус); своё время уведомления — момент показа, он и ставит его
            // среди свежих (см. выше про строку состояния)
            .setShowWhen(false)
            .setTimeoutAfter(e.end - now)
        if (card != null) b.setCustomContentView(card.first).setCustomBigContentView(card.second)
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
        for (m in members.take(MAX_LINES)) inbox.addLine(shownTitle(c, m, now))
        val b = NotificationCompat.Builder(c, CHANNEL)
            .setSmallIcon(icon(c))
            .setContentTitle(title)
            .setContentText(shownTitle(c, members.first(), now))
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

    /**
     * Новое расписание. [watch] — адрес файла состояния стартов; [finished] — старты, которые по данным
     * приложения уже закончились (до какого момента это помнить): их уведомления не возвращаются,
     * даже если позже придёт расписание, где они ещё идут (фоновое обновление без итогов с табло).
     */
    @Synchronized
    fun sync(c: Context, list: List<Entry>, watch: String = "", finished: Map<String, Long> = emptyMap()) {
        ensureChannel(c)
        val now = System.currentTimeMillis()
        prefs(c).edit().putString("watch", watch).apply()
        val done = done(c, now)
        for ((k, v) in finished) if (v > now && v > (done[k] ?: 0L)) done[k] = v
        saveDone(c, done)
        val old = load(c)
        val f = fired(c)
        val next = LinkedHashMap<String, Entry>()
        for (e in list) if (e.end > now && (e.start.isEmpty() || e.start !in done)) next[e.key] = e
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
        f.retainAll(next.keys)
        val loud = ArrayList<Entry>()
        val quiet = ArrayList<Entry>()
        for (e in next.values) {
            val p = old[e.key]
            if (e.key in f && e.at > now + REFIRE) {
                // старт перенесли на потом — висящее о прежнем времени снимаем, придёт заново в новое
                f.remove(e.key)
                NotificationManagerCompat.from(c).cancel(e.id)
                touched.add(e.group)
                gone.add(e.id)
            }
            if (e.key in f) {
                // показано: текст поменялся, спортсмен уже откатал или сдвинулся конец — обновить тихо
                if (p == null || !p.sameText(e, now) || (p.hold > now) != (e.hold > now) || p.end != e.end) {
                    if (active(c, e)) quiet.add(e)
                }
                cancel(c, intent(c, FIRE, e.id))
                cancel(c, intent(c, RELEASE, e.id))
                setRelease(c, e)
                setLive(c, e)
            } else if (e.at > now) {
                setAlarm(c, e)
                setRelease(c, e)
                setLive(c, e)
            } else if (now < e.late) {
                // время показа прошло, а показано не было — показать сейчас, со звуком
                cancel(c, intent(c, FIRE, e.id))
                f.add(e.key)
                loud.add(e)
                setRelease(c, e)
                setLive(c, e)
            } else {
                cancelAlarm(c, e)
            }
        }
        saveFired(c, f)
        for (g in touched) regroup(c, g, gone = gone)
        for (e in quiet) post(c, e, quiet = true)
        for (e in loud) post(c, e, quiet = false)
        scheduleTick(c)
        scheduleWatch(c)
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
        scheduleWatch(c)
    }

    // ---------------------------------------------------------------- из будильника и системы

    @Synchronized
    fun fire(c: Context, id: Int) {
        val e = load(c).values.firstOrNull { it.id == id } ?: return
        val f = fired(c)
        val now = System.currentTimeMillis()
        // будильник в экономии энергии мог прийти поздно: о том, что уже прошло, не сообщаем
        if (e.key in f || e.end <= now || now >= e.late) return
        if (e.start.isNotEmpty() && e.start in done(c, now)) return
        f.add(e.key)
        saveFired(c, f)
        post(c, e, quiet = false)
        scheduleTick(c)
        scheduleWatch(c)
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

    /** Старт начался — в висящем уведомлении о нём статус вместо времени начала, тихо. Смахнутое не возвращаем. */
    @Synchronized
    fun live(c: Context, id: Int) {
        val e = load(c).values.firstOrNull { it.id == id } ?: return
        if (e.key in fired(c) && active(c, e)) post(c, e, quiet = true)
        scheduleWatch(c)
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

    /**
     * Спросить файл состояния и применить. Вызывается из будильника в отдельном потоке: сеть — вне
     * блокировки, применение — под ней. Сеть недоступна (экономия энергии, нет связи) — до следующего раза.
     */
    fun watch(c: Context) {
        val url = prefs(c).getString("watch", "") ?: ""
        val starts = if (url.isEmpty()) null else fetchStarts(url)
        if (starts != null) applyNow(c, starts)
        synchronized(this) { scheduleWatch(c) }
    }

    private fun fetchStarts(url: String): JSONObject? {
        var con: HttpURLConnection? = null
        return try {
            // минута в адресе — мимо кэша сети раздачи, как у загрузки расписания в приложении
            val u = url + (if ('?' in url) "&" else "?") + "t=" + System.currentTimeMillis() / 60_000
            con = (URL(u).openConnection() as HttpURLConnection).apply {
                connectTimeout = 8_000
                readTimeout = 8_000
                useCaches = false
            }
            if (con.responseCode != 200) return null
            val text = con.inputStream.bufferedReader().use { it.readText() }
            JSONObject(text).optJSONObject("starts")
        } catch (_: Exception) {
            null
        } finally {
            con?.disconnect()
        }
    }

    /**
     * Старт закончился — все его уведомления снять сейчас и не возвращать. Затянулся (табло: места
     * промежуточные, выступили не все) — продлить, чтобы не снялись в конец по расписанию; не дольше
     * трёх часов после него, как и в приложении.
     */
    @Synchronized
    fun applyNow(c: Context, starts: JSONObject) {
        val now = System.currentTimeMillis()
        val plan = load(c)
        val f = fired(c)
        val done = done(c, now)
        val touched = HashSet<String>()
        val gone = HashSet<Int>()
        val repost = ArrayList<Entry>()
        var changed = false
        for (id in plan.values.map { it.start }.filter { it.isNotEmpty() }.toSet()) {
            val s = starts.optJSONObject(id) ?: continue
            val t1 = s.optLong("t1")
            val mine = plan.values.filter { it.start == id }
            if (s.optBoolean("done")) {
                done[id] = maxOf(done[id] ?: 0L, if (t1 > 0) t1 + OVERRUN else now + OVERRUN)
                for (e in mine) {
                    plan.remove(e.key)
                    f.remove(e.key)
                    cancelAlarm(c, e)
                    NotificationManagerCompat.from(c).cancel(e.id)
                    touched.add(e.group)
                    gone.add(e.id)
                }
                changed = true
            } else if (s.optBoolean("run") && t1 > 0 && now < t1 + OVERRUN) {
                // конец уведомления о старте; с ним кончаются и уведомления о выходе, у которых тот же конец
                val startEnd = mine.filter { !it.reminder }.maxOfOrNull { it.end } ?: continue
                if (startEnd > now + RUN_MARGIN) continue
                val until = minOf(now + RUN_AHEAD, t1 + OVERRUN)
                if (until <= startEnd) continue
                for (e in mine) {
                    if (e.end < startEnd) continue
                    val x = e.until(until)
                    plan[e.key] = x
                    if (x.key in f && active(c, x)) repost.add(x)
                }
                changed = true
            }
        }
        if (!changed) return
        save(c, plan)
        saveFired(c, f)
        saveDone(c, done)
        for (g in touched) regroup(c, g, gone = gone)
        for (x in repost) {
            post(c, x, quiet = true)
            cancel(c, intent(c, RELEASE, x.id))
            setRelease(c, x)
        }
        scheduleTick(c)
    }

    /** После перезагрузки, обновления приложения, смены времени: будильники заново, пропущенное — показать, если не поздно. */
    @Synchronized
    fun restore(c: Context) {
        ensureChannel(c)
        val now = System.currentTimeMillis()
        val plan = load(c)
        val f = fired(c)
        val done = done(c, now)
        val keep = LinkedHashMap<String, Entry>()
        for (e in plan.values) {
            if (e.end <= now || (e.start.isNotEmpty() && e.start in done)) continue
            keep[e.key] = e
        }
        save(c, keep)
        f.retainAll(keep.keys)
        val loud = ArrayList<Entry>()
        val quiet = ArrayList<Entry>()
        for (e in keep.values) {
            if (e.key in f) {
                // перезагрузка стёрла закреплённое — вернуть
                if (!active(c, e) && e.hold > now) quiet.add(e)
                setRelease(c, e)
            } else if (e.at > now) {
                setAlarm(c, e)
                setRelease(c, e)
            } else if (now < e.late) {
                f.add(e.key)
                loud.add(e)
                setRelease(c, e)
            }
            setLive(c, e)
        }
        saveFired(c, f)
        for (e in quiet) post(c, e, quiet = true)
        for (e in loud) post(c, e, quiet = false)
        scheduleTick(c)
        scheduleWatch(c)
    }
}

class AlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "ru.furya.starty.alerts.WATCH") {
            // сеть — не в главном потоке; система ждёт окончания (goAsync)
            val pending = goAsync()
            Thread {
                try {
                    Alerts.watch(context.applicationContext)
                } catch (_: Throwable) {
                } finally {
                    pending.finish()
                }
            }.start()
            return
        }
        val id = intent.data?.host?.toIntOrNull() ?: return
        when (intent.action) {
            "ru.furya.starty.alerts.FIRE" -> Alerts.fire(context, id)
            "ru.furya.starty.alerts.DELETED" -> Alerts.deleted(context, id)
            "ru.furya.starty.alerts.RELEASE" -> Alerts.release(context, id)
            "ru.furya.starty.alerts.TICK" -> Alerts.tick(context)
            "ru.furya.starty.alerts.LIVE" -> Alerts.live(context, id)
        }
    }
}

class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Alerts.restore(context)
    }
}
