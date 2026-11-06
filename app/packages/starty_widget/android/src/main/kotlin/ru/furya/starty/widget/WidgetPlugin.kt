package ru.furya.starty.widget

import android.app.Activity
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Канал starty/widget — и в основном движке, и в фоновом (обновление расписания): данные для виджета
 * «Месяц», поставить его на рабочий стол, и куда открыть приложение по нажатию на виджет.
 */
class WidgetPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, PluginRegistry.NewIntentListener {
    private var channel: MethodChannel? = null
    private var ctx: Context? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ctx = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "starty/widget").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        ctx = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        activity = b.activity
        binding = b
        b.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    override fun onDetachedFromActivity() {
        binding?.removeOnNewIntentListener(this)
        binding = null
        activity = null
    }

    /** Приложение уже открыто, нажали на виджет: сказать, куда перейти. */
    override fun onNewIntent(intent: Intent): Boolean {
        val what = take(intent) ?: return false
        channel?.invokeMethod("open", what)
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val c = ctx ?: return result.error("detached", "нет контекста", null)
        try {
            when (call.method) {
                "publish" -> {
                    MonthWidget.publish(c, call.arguments as String)
                    result.success(null)
                }
                "status" -> result.success(mapOf("placed" to MonthWidget.placed(c).size, "canPin" to MonthWidget.canPin(c)))
                "pin" -> result.success(MonthWidget.pin(c))
                // запуск с виджета: куда открыть (один раз)
                "takeOpen" -> result.success(activity?.intent?.let { take(it) })
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("widget", e.message, null)
        }
    }

    /** Куда открыть — и забыть: запуск из недавних отдаёт старый интент ещё раз, по нему не переходим. */
    private fun take(i: Intent): String? {
        val what = i.getStringExtra(MonthWidget.EXTRA_OPEN) ?: return null
        i.removeExtra(MonthWidget.EXTRA_OPEN)
        if (i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        return what
    }
}
