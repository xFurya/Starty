package ru.furya.starty.alerts

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Канал starty/alerts — и в основном, и в фоновом (обновление расписания) движке. */
class AlertsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var ctx: Context? = null

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        ctx = b.applicationContext
        channel = MethodChannel(b.binaryMessenger, "starty/alerts").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        ctx = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val c = ctx ?: return result.error("detached", "нет контекста", null)
        try {
            when (call.method) {
                "sync" -> {
                    val list = (call.arguments as List<*>).mapNotNull { m ->
                        @Suppress("UNCHECKED_CAST")
                        val x = m as? Map<String, Any?> ?: return@mapNotNull null
                        Entry(
                            key = x["key"] as String,
                            at = (x["at"] as Number).toLong(),
                            end = (x["end"] as Number).toLong(),
                            title = x["title"] as? String ?: "",
                            body = x["body"] as? String ?: "",
                        )
                    }
                    Alerts.sync(c, list)
                    result.success(null)
                }
                "clear" -> {
                    Alerts.clear(c)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("alerts", e.message, null)
        }
    }
}
