package ru.furya.starty

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import java.util.Calendar

/**
 * Иконка приложения. В лаунчере — псевдонимы активности (activity-alias, см. манифест и
 * tools/icons/make.py): классическая «.MainActivity», «.icon.skate_*» и «.icon.date_<цвет>_<день>».
 * Включён ровно один. У «Календаря» число в значке — сегодняшнее: в полночь включается
 * псевдоним следующего дня (точный будильник), а при запуске, перезагрузке и смене времени
 * сверяется ещё раз.
 */
object AppIcons {
    private const val PREFS = "app_icon"
    const val CLASSIC = "classic"

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun current(c: Context): String = prefs(c).getString("variant", CLASSIC) ?: CLASSIC

    /** Запомнить выбор. Ставится, когда приложение уйдёт с экрана: выключение псевдонима,
     *  через который приложение запущено, на части лаунчеров закрывает его. */
    fun set(c: Context, variant: String) {
        prefs(c).edit().putString("variant", variant).apply()
    }

    private fun aliasFor(c: Context, variant: String): String {
        val base = c.packageName
        if (variant == CLASSIC) return "$base.MainActivity"
        if (variant.startsWith("date_")) return "$base.icon.${variant}_${Calendar.getInstance().get(Calendar.DAY_OF_MONTH)}"
        return "$base.icon.$variant"
    }

    /** Все псевдонимы-иконки приложения (включённые и выключенные). */
    private fun aliases(c: Context): List<android.content.pm.ActivityInfo> {
        val pm = c.packageManager
        @Suppress("DEPRECATION")
        val flags = PackageManager.GET_ACTIVITIES or PackageManager.GET_DISABLED_COMPONENTS
        val info = pm.getPackageInfo(c.packageName, flags)
        val base = c.packageName
        return (info.activities ?: emptyArray()).filter {
            it.targetActivity != null && (it.name == "$base.MainActivity" || it.name.startsWith("$base.icon."))
        }
    }

    private fun enabled(pm: PackageManager, c: Context, a: android.content.pm.ActivityInfo): Boolean =
        when (pm.getComponentEnabledSetting(ComponentName(c, a.name))) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> a.enabled
            else -> false
        }

    /** Включить нужный псевдоним и выключить остальные. Уже так — ничего не трогаем. */
    @Synchronized
    fun apply(c: Context) {
        val variant = current(c)
        val pm = c.packageManager
        val all = try { aliases(c) } catch (_: Exception) { return }
        var want = aliasFor(c, variant)
        if (all.none { it.name == want }) want = aliasFor(c, CLASSIC) // вариант пропал в новой версии
        val flags = PackageManager.DONT_KILL_APP
        // сначала включаем новый — чтобы ни на миг не остаться без значка
        all.firstOrNull { it.name == want }?.let {
            if (!enabled(pm, c, it)) {
                pm.setComponentEnabledSetting(ComponentName(c, it.name), PackageManager.COMPONENT_ENABLED_STATE_ENABLED, flags)
            }
        }
        for (a in all) {
            if (a.name != want && enabled(pm, c, a)) {
                pm.setComponentEnabledSetting(ComponentName(c, a.name), PackageManager.COMPONENT_ENABLED_STATE_DISABLED, flags)
            }
        }
        schedule(c, variant.startsWith("date_"))
    }

    private fun pending(c: Context): PendingIntent = PendingIntent.getBroadcast(
        c, 0, Intent(c, IconReceiver::class.java).setAction("ru.furya.starty.ICON_DAY"),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** Будильник на ближайшую полночь — только пока выбран «Календарь». */
    private fun schedule(c: Context, on: Boolean) {
        val am = c.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = pending(c)
        if (!on) {
            am.cancel(pi)
            return
        }
        val next = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_MONTH, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 1)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        try {
            if (Build.VERSION.SDK_INT >= 31 && !am.canScheduleExactAlarms()) {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi)
            } else {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi)
            }
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi)
        }
    }
}

/** Полночь, перезагрузка, смена времени или часового пояса, обновление — сверить иконку. */
class IconReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        // приложение на экране — поставим, когда уйдёт (onStop)
        if (Updater.visible) return
        try { AppIcons.apply(context) } catch (_: Exception) {}
    }
}
