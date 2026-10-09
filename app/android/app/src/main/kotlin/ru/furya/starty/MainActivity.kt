package ru.furya.starty

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var lastCheck = 0L
    private val onChange: () -> Unit = { runOnUiThread { channel?.invokeMethod("changed", Updater.statusJson(this)) } }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "starty/update")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(Updater.statusJson(this))
                "check" -> { Updater.check(this); result.success(null) }
                "install" -> thread(name = "update-install") {
                    val r = try { Updater.install(applicationContext, fromUser = true) } catch (e: Throwable) { e.message ?: "ошибка" }
                    runOnUiThread { result.success(r) }
                }
                "openInstaller" -> result.success(Updater.openInstaller(this))
                "allowInstall" -> result.success(Updater.openInstallPermission(this))
                // «Разрешить» уведомления, когда система больше не спрашивает сама
                "notifySettings" -> result.success(openNotificationSettings())
                else -> result.notImplemented()
            }
        }
        Updater.listener = onChange
    }

    /** Системный экран уведомлений этого приложения (до Android 8 — сведения о приложении). */
    private fun openNotificationSettings(): Boolean = try {
        val i = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        }
        startActivity(i)
        true
    } catch (_: Exception) {
        false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Восстановление после гибели процесса или запуск из недавних отдают старый интент
        // уведомления ещё раз — повторно ставить по нему нельзя.
        if (savedInstanceState != null || (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) {
            intent.removeExtra(Updater.EXTRA_INSTALL)
        }
        super.onCreate(savedInstanceState)
        Updater.schedule(this)
    }

    override fun onStart() {
        super.onStart()
        Updater.onStart()
    }

    override fun onResume() {
        super.onResume()
        Updater.clearNotice(this)
        if (intent?.getBooleanExtra(Updater.EXTRA_INSTALL, false) == true) {
            intent.removeExtra(Updater.EXTRA_INSTALL)
            thread(name = "update-install") { try { Updater.install(applicationContext, fromUser = true) } catch (_: Throwable) {} }
        } else if (System.currentTimeMillis() - lastCheck > 60_000L) {
            lastCheck = System.currentTimeMillis()
            Updater.check(this)
        }
    }

    override fun onStop() {
        super.onStop()
        Updater.onStop()
        // Свернули — обновление встанет через минуту, если к тому времени не вернутся.
        if (!Updater.visible) Updater.installSoon(applicationContext)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onDestroy() {
        if (Updater.listener === onChange) Updater.listener = null
        channel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}
