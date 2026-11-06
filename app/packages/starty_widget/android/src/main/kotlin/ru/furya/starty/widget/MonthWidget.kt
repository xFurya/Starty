package ru.furya.starty.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StyleSpan
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone

/**
 * Виджет «Месяц» (подписка): месяц со стартами, как во вкладке «Месяц» — точки видов под днями,
 * полая точка — турнир без расписания, сегодня в кольце, прошедшее приглушено. Стрелки листают
 * месяцы; день открывает приложение на этом дне, название месяца — на этом месяце.
 *
 * Что показывать, решает приложение (WidgetPlugin.publish → [publish]): дни со стартами под его
 * фильтром, когда обновлено расписание, есть ли подписка. Сам виджет считает только «сегодня»
 * (по Москве, как приложение) и устарело ли расписание — это меняется без приложения.
 */
class MonthWidget : AppWidgetProvider() {

    override fun onUpdate(c: Context, m: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(c, m, id)
        schedule(c)
    }

    override fun onAppWidgetOptionsChanged(c: Context, m: AppWidgetManager, id: Int, o: Bundle?) = render(c, m, id)

    override fun onDeleted(c: Context, ids: IntArray) {
        val e = prefs(c).edit()
        for (id in ids) e.remove(OFFSET + id)
        e.apply()
    }

    override fun onDisabled(c: Context) {
        // убрали последний: без подписки виджета снова нет в списке
        cancelTick(c)
        if (!active(load(c), System.currentTimeMillis())) setAvailable(c, false)
    }

    override fun onReceive(c: Context, i: Intent) {
        when (i.action) {
            ACTION_PREV, ACTION_NEXT -> {
                val id = i.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
                if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
                val p = prefs(c)
                val off = p.getInt(OFFSET + id, 0) + if (i.action == ACTION_NEXT) 1 else -1
                p.edit().putInt(OFFSET + id, off).apply()
                render(c, AppWidgetManager.getInstance(c), id)
            }
            // полночь по Москве или расписание устарело — перерисовать; наступил новый день —
            // листанные возвращаются к текущему месяцу
            ACTION_TICK -> {
                val p = prefs(c)
                val day = todayKey()
                if (p.getString(DAY, null) != day) {
                    val e = p.edit().putString(DAY, day)
                    for (k in p.all.keys) if (k.startsWith(OFFSET)) e.remove(k)
                    e.apply()
                }
                renderAll(c)
            }
            Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED -> renderAll(c)
            else -> super.onReceive(c, i)
        }
    }

    /** Что прислало приложение. */
    class Data(
        val mode: String,
        /** Когда кончается подписка, по часам телефона (0 — не сказано): дальше виджет закрыт сам. */
        val until: Long,
        val days: Map<String, Int>,
        val generated: Long,
        val trouble: String,
        val filter: String,
        val lockTitle: String,
        val lockText: String,
        val lockOpen: String,
    )

    companion object {
        private const val PREFS = "starty_widget"
        private const val DATA = "data"
        private const val OFFSET = "off."
        private const val DAY = "day"
        const val ACTION_PREV = "ru.furya.starty.widget.PREV"
        const val ACTION_NEXT = "ru.furya.starty.widget.NEXT"
        const val ACTION_TICK = "ru.furya.starty.widget.TICK"

        /** Что открыть в приложении: «day:2026-11-12», «month:2026-11», «billing». */
        const val EXTRA_OPEN = "starty.widget.open"

        const val MODE_ON = "on"

        /** Виды — биты дня: как в month_widget.dart. */
        private const val WOMEN = 1
        private const val MEN = 2
        private const val PAIRS = 4
        private const val DANCE = 8
        private const val OTHER = 16
        private const val HOLLOW = 32
        private const val STARTS = WOMEN or MEN or PAIRS or DANCE or OTHER

        /** Сборщик ходит дважды в день; старше 20 часов — запуск не состоялся (как freshness в приложении). */
        private const val STALE_MS = 20L * 3600 * 1000

        /** Время приложения — московское, без перехода на летнее (data.dart: msk). */
        private val MSK: TimeZone = TimeZone.getTimeZone("GMT+03:00")

        private val MONTHS = arrayOf(
            "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
            "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
        )
        private val MONTHS_OF = arrayOf(
            "января", "февраля", "марта", "апреля", "мая", "июня",
            "июля", "августа", "сентября", "октября", "ноября", "декабря",
        )

        private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        private fun component(c: Context) = ComponentName(c, MonthWidget::class.java)

        fun placed(c: Context): IntArray = try {
            AppWidgetManager.getInstance(c).getAppWidgetIds(component(c))
        } catch (_: Exception) {
            IntArray(0)
        }

        /** Данные от приложения: сохранить, открыть или закрыть виджет в списке, перерисовать. */
        fun publish(c: Context, json: String) {
            prefs(c).edit().putString(DATA, json).apply()
            val on = active(load(c), System.currentTimeMillis())
            // поставленный остаётся и без подписки — говорит, что входит в подписку
            setAvailable(c, on || placed(c).isNotEmpty())
            renderAll(c)
        }

        /** Виджет в списке виджетов рабочего стола: только с подпиской (или уже поставленный). */
        private fun setAvailable(c: Context, on: Boolean) {
            val pm = c.packageManager
            val want = if (on) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
            try {
                if (pm.getComponentEnabledSetting(component(c)) != want) {
                    pm.setComponentEnabledSetting(component(c), want, PackageManager.DONT_KILL_APP)
                }
            } catch (_: Exception) {}
        }

        /** Рабочий стол умеет ставить виджет по просьбе приложения (Android 8+, не всякий лаунчер). */
        fun canPin(c: Context): Boolean = Build.VERSION.SDK_INT >= 26 &&
            try { AppWidgetManager.getInstance(c).isRequestPinAppWidgetSupported } catch (_: Exception) { false }

        /** Попросить рабочий стол поставить виджет: дальше человек сам подтверждает и выбирает место. */
        fun pin(c: Context): Boolean {
            if (!canPin(c) || !active(load(c), System.currentTimeMillis())) return false
            return try {
                AppWidgetManager.getInstance(c).requestPinAppWidget(component(c), null, null)
            } catch (_: Exception) {
                false
            }
        }

        fun load(c: Context): Data? {
            val raw = prefs(c).getString(DATA, null) ?: return null
            return try {
                val j = JSONObject(raw)
                val days = HashMap<String, Int>()
                j.optJSONObject("days")?.let { d -> for (k in d.keys()) days[k] = d.optInt(k) }
                Data(
                    mode = j.optString("mode"),
                    until = j.optLong("until"),
                    days = days,
                    generated = j.optLong("generated"),
                    trouble = j.optString("trouble"),
                    filter = j.optString("filter"),
                    lockTitle = j.optString("lockTitle"),
                    lockText = j.optString("lockText"),
                    lockOpen = j.optString("lockOpen"),
                )
            } catch (_: Exception) {
                null
            }
        }

        /** Подписка действует: приложение так сказало, и срок, который оно назвало, ещё не прошёл. */
        private fun active(d: Data?, now: Long) = d != null && d.mode == MODE_ON && (d.until <= 0 || now < d.until)

        fun renderAll(c: Context) {
            val m = AppWidgetManager.getInstance(c)
            val ids = placed(c)
            for (id in ids) render(c, m, id)
            if (ids.isNotEmpty()) schedule(c) else cancelTick(c)
        }

        private fun render(c: Context, m: AppWidgetManager, id: Int) {
            val views = try {
                build(c, id)
            } catch (_: Exception) {
                message(c, "Месяц", "Не удалось показать. Откройте приложение", "")
            }
            try {
                m.updateAppWidget(id, views)
            } catch (_: Exception) {}
        }

        private fun build(c: Context, id: Int): RemoteViews {
            val d = load(c) ?: return message(c, "Месяц", "Откройте приложение — расписание ещё не загружено", "")
            val now = System.currentTimeMillis()
            if (!active(d, now)) return message(c, d.lockTitle, d.lockText, d.lockOpen)
            val cal = Calendar.getInstance(MSK).apply { timeInMillis = now }
            val today = key(cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH))
            prefs(c).let { if (it.getString(DAY, null) == null) it.edit().putString(DAY, today).apply() }
            cal.set(Calendar.DAY_OF_MONTH, 1)
            cal.add(Calendar.MONTH, prefs(c).getInt(OFFSET + id, 0))
            val year = cal.get(Calendar.YEAR)
            val month = cal.get(Calendar.MONTH)
            val days = cal.getActualMaximum(Calendar.DAY_OF_MONTH)
            // понедельник — первый
            val lead = (cal.get(Calendar.DAY_OF_WEEK) + 5) % 7

            val v = RemoteViews(c.packageName, R.layout.widget_month)
            v.setTextViewText(R.id.month, MONTHS[month])
            v.setTextViewText(R.id.year, "$year")
            v.setOnClickPendingIntent(R.id.head, open(c, "month:%04d-%02d".format(year, month + 1), year * 100 + month + 1))
            v.setOnClickPendingIntent(R.id.prev, step(c, id, ACTION_PREV))
            v.setOnClickPendingIntent(R.id.next, step(c, id, ACTION_NEXT))

            // честная строка: расписание старое или неполное — первым; фильтр — потом
            val alarm = when {
                d.generated > 0 && now - d.generated > STALE_MS -> {
                    val g = Calendar.getInstance(MSK).apply { timeInMillis = d.generated }
                    "Расписание устарело, обновлено ${g.get(Calendar.DAY_OF_MONTH)} ${MONTHS_OF[g.get(Calendar.MONTH)]}"
                }
                else -> d.trouble
            }
            val note = listOf(alarm, if (d.filter.isEmpty()) "" else "Фильтр: ${d.filter}").filter { it.isNotEmpty() }
            if (note.isEmpty()) {
                v.setViewVisibility(R.id.note, View.GONE)
            } else {
                v.setViewVisibility(R.id.note, View.VISIBLE)
                v.setTextViewText(R.id.note, note.joinToString("\n"))
                color(c, v, R.id.note, if (alarm.isNotEmpty()) R.color.widget_live else R.color.widget_ink2)
            }

            v.removeAllViews(R.id.grid)
            val rows = (lead + days + 6) / 7
            for (r in 0 until rows) {
                val row = RemoteViews(c.packageName, R.layout.widget_row)
                for (col in 0 until 7) {
                    val n = r * 7 + col - lead + 1
                    row.addView(R.id.row, cell(c, if (n in 1..days) n else 0, year, month, today, d.days))
                }
                v.addView(R.id.grid, row)
            }
            return v
        }

        private fun cell(c: Context, n: Int, year: Int, month: Int, today: String, marks: Map<String, Int>): RemoteViews {
            val v = RemoteViews(c.packageName, R.layout.widget_cell)
            if (n == 0) {
                v.setTextViewText(R.id.num, "")
                v.setInt(R.id.cell, "setBackgroundResource", 0)
                return v
            }
            val k = key(year, month, n)
            val bits = marks[k] ?: 0
            val isToday = k == today
            val past = k < today
            val starts = bits and STARTS != 0
            val text = SpannableString("$n")
            if (isToday || starts) text.setSpan(StyleSpan(Typeface.BOLD), 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            v.setTextViewText(R.id.num, text)
            color(
                c, v, R.id.num,
                when {
                    isToday -> R.color.widget_accent
                    starts -> if (past) R.color.widget_ink2 else R.color.widget_ink
                    bits and HOLLOW != 0 -> R.color.widget_ink2
                    else -> R.color.widget_ink3
                },
            )
            if (isToday) v.setInt(R.id.num, "setBackgroundResource", R.drawable.widget_today)
            val dots = arrayOf(
                WOMEN to R.id.d_women, MEN to R.id.d_men, PAIRS to R.id.d_pairs,
                DANCE to R.id.d_dance, OTHER to R.id.d_other, HOLLOW to R.id.d_ring,
            )
            for ((bit, dot) in dots) {
                if (bits and bit == 0) continue
                v.setViewVisibility(dot, View.VISIBLE)
                if (past) v.setInt(dot, "setImageAlpha", 140)
            }
            v.setOnClickPendingIntent(R.id.cell, open(c, "day:$k", year * 10000 + (month + 1) * 100 + n))
            v.setContentDescription(R.id.cell, "$n ${MONTHS_OF[month]}")
            return v
        }

        /**
         * Цвет по теме. С Android 12 рабочий стол сам берёт светлый или тёмный при смене темы; раньше —
         * тот, что был при отрисовке (фон, точки и кольцо — ресурсы и меняются сами всегда).
         */
        private fun color(c: Context, v: RemoteViews, id: Int, res: Int) {
            if (Build.VERSION.SDK_INT >= 31) {
                v.setColor(id, "setTextColor", res)
            } else {
                v.setTextColor(id, c.getColor(res))
            }
        }

        private fun message(c: Context, title: String, text: String, what: String): RemoteViews {
            val v = RemoteViews(c.packageName, R.layout.widget_message)
            v.setTextViewText(R.id.msg_title, title)
            v.setTextViewText(R.id.msg_text, text)
            v.setOnClickPendingIntent(android.R.id.background, open(c, what, if (what.isEmpty()) 2 else 1))
            return v
        }

        private fun key(year: Int, month: Int, day: Int) = "%04d-%02d-%02d".format(year, month + 1, day)

        private fun todayKey(): String {
            val cal = Calendar.getInstance(MSK)
            return key(cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH))
        }

        /** Открыть приложение; [what] — куда (пусто — просто открыть). Уже открытое получает это в onNewIntent. */
        private fun open(c: Context, what: String, code: Int): PendingIntent? {
            val i = c.packageManager.getLaunchIntentForPackage(c.packageName) ?: return null
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (what.isNotEmpty()) i.putExtra(EXTRA_OPEN, what)
            return PendingIntent.getActivity(c, code, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        private fun step(c: Context, id: Int, action: String): PendingIntent {
            val i = Intent(c, MonthWidget::class.java).setAction(action).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            return PendingIntent.getBroadcast(c, id, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        private fun tick(c: Context): PendingIntent = PendingIntent.getBroadcast(
            c, 0, Intent(c, MonthWidget::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        /**
         * Перерисовать без приложения: в полночь по Москве (сегодня переехало), когда расписание станет
         * старым (строка «устарело») и когда кончится подписка. Будильник не будит телефон — придёт,
         * когда тот проснётся.
         */
        private fun schedule(c: Context) {
            val now = System.currentTimeMillis()
            val cal = Calendar.getInstance(MSK).apply {
                timeInMillis = now
                add(Calendar.DAY_OF_MONTH, 1)
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 30)
                set(Calendar.MILLISECOND, 0)
            }
            var at = cal.timeInMillis
            val d = load(c)
            val g = d?.generated ?: 0L
            if (g > 0 && g + STALE_MS in (now + 1)..at) at = g + STALE_MS + 1000
            // срок подписки — закрыться вовремя
            val u = d?.until ?: 0L
            if (u in (now + 1)..at) at = u + 1000
            try {
                (c.getSystemService(Context.ALARM_SERVICE) as AlarmManager).set(AlarmManager.RTC, at, tick(c))
            } catch (_: Exception) {}
        }

        private fun cancelTick(c: Context) {
            try {
                (c.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(tick(c))
            } catch (_: Exception) {}
        }
    }
}
