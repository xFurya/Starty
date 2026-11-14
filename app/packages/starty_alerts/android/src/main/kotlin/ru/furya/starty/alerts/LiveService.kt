package ru.furya.starty.alerts

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Живое уведомление идущего старта: пока старт с уведомлением-карточкой идёт, служба переднего плана
 * держит фоновый движок Flutter со входом liveCardMain (live_card.dart). Он сам читает табло турнира —
 * без приложения на экране и без сервера — и отдаёт данные карточки, а Alerts перерисовывает
 * уведомление (полоса выступлений, на льду и далее, тройка, ваши, время табло).
 *
 * Уведомлением службы служит само уведомление о старте (тот же номер), второго не появляется.
 * Стартов с живым уведомлением не осталось — движок говорит «idle», служба останавливается, а
 * уведомление остаётся как было (или снимается, если его старта больше нет).
 *
 * Запуск — из точного будильника в начало старта (такой будильник вправе поднять службу из фона),
 * из приложения на экране и после перезагрузки. Не вышло (система не дала) — уведомление остаётся
 * обычной карточкой, ничего не ломается.
 */
class LiveService : Service() {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var fgId = 0
    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val fg = Alerts.liveForeground(this)
        if (!foreground(fg?.first ?: PLACEHOLDER, fg?.second ?: placeholder())) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (fg == null) {
            // старт кончился между просьбой и запуском: обещание системе выполнено — и сразу на выход
            finish()
            return START_NOT_STICKY
        }
        if (engine == null) startEngine()
        return START_NOT_STICKY
    }

    private fun foreground(id: Int, n: Notification): Boolean = try {
        ServiceCompat.startForeground(
            this, id, n,
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0,
        )
        fgId = id
        true
    } catch (_: Exception) {
        false
    }

    /** Нужен только если старт успел закончиться: система ждёт уведомление от службы в любом случае. */
    private fun placeholder(): Notification {
        Alerts.ensureChannel(this)
        return NotificationCompat.Builder(this, Alerts.CHANNEL)
            .setSmallIcon(Alerts.icon(this))
            .setContentTitle("Старт закончился")
            .setSilent(true)
            .build()
    }

    private fun startEngine() {
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val e = FlutterEngine(applicationContext)
            channel = MethodChannel(e.dartExecutor.binaryMessenger, "starty/live").also {
                it.setMethodCallHandler { call, result -> onCall(call, result) }
            }
            e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "liveCardMain"))
            engine = e
        } catch (_: Throwable) {
            finish()
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "starts" -> {
                    val list = Alerts.liveEntries(this)
                    // уведомление службы — всегда о старте, который ещё идёт
                    if (list.isNotEmpty() && list.none { it["id"] == fgId.toString() }) {
                        Alerts.liveForeground(this)?.let { foreground(it.first, it.second) }
                    }
                    result.success(list)
                }
                "update" -> {
                    Alerts.liveUpdate(this, call.argument<String>("key") ?: "", call.argument<String>("card") ?: "")
                    result.success(null)
                }
                "idle" -> {
                    result.success(null)
                    finish()
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("live", e.message, null)
        }
    }

    private fun finish() {
        main.post {
            // уведомление старта остаётся висеть (оно же уведомление службы); его старта нет — убрать
            val keep = fgId != PLACEHOLDER && Alerts.hasShown(this, fgId)
            try {
                ServiceCompat.stopForeground(
                    this,
                    if (keep) ServiceCompat.STOP_FOREGROUND_DETACH else ServiceCompat.STOP_FOREGROUND_REMOVE,
                )
            } catch (_: Exception) {
            }
            if (!keep && fgId != PLACEHOLDER && fgId != 0) NotificationManagerCompat.from(this).cancel(fgId)
            stopSelf()
        }
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        finish()
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        try {
            engine?.destroy()
        } catch (_: Throwable) {
        }
        engine = null
        super.onDestroy()
    }

    companion object {
        private const val PLACEHOLDER = 0x5717

        /** Поднять службу, если есть идущий старт с живым уведомлением. Система не дала — молча. */
        fun start(c: Context) {
            if (Alerts.liveEntries(c).isEmpty()) return
            try {
                ContextCompat.startForegroundService(c, Intent(c, LiveService::class.java))
            } catch (_: Exception) {
            }
        }
    }
}
