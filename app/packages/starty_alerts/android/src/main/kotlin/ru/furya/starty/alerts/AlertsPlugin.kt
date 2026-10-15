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
                            hold = (x["hold"] as? Number)?.toLong() ?: (x["end"] as Number).toLong(),
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
                // звук, вибрация, всплывание и экран блокировки — настройки канала в системе
                "channelSettings" -> {
                    Alerts.ensureChannel(c)
                    val i = if (android.os.Build.VERSION.SDK_INT >= 26) {
                        android.content.Intent(android.provider.Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, c.packageName)
                            .putExtra(android.provider.Settings.EXTRA_CHANNEL_ID, Alerts.CHANNEL)
                    } else {
                        android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(android.net.Uri.parse("package:" + c.packageName))
                    }
                    c.startActivity(i.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("alerts", e.message, null)
        }
    }
}
