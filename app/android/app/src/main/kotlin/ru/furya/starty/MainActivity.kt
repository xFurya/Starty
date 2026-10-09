package ru.furya.starty

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var lastCheck = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "starty/update")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(Updater.statusJson(this))
                "check" -> { Updater.check(this); result.success(null) }
                "install" -> thread(name = "update-install") {
                    val r = Updater.install(applicationContext, fromUser = true)
                    runOnUiThread { result.success(r) }
                }
                "openInstaller" -> result.success(Updater.openInstaller(this))
                else -> result.notImplemented()
            }
        }
        Updater.listener = { runOnUiThread { channel?.invokeMethod("changed", Updater.statusJson(this)) } }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Updater.schedule(this)
    }

    override fun onResume() {
        super.onResume()
        visible = true
        Updater.clearNotice(this)
        if (intent?.getBooleanExtra(Updater.EXTRA_INSTALL, false) == true) {
            intent.removeExtra(Updater.EXTRA_INSTALL)
            thread(name = "update-install") { Updater.install(applicationContext, fromUser = true) }
        } else if (System.currentTimeMillis() - lastCheck > 60_000L) {
            lastCheck = System.currentTimeMillis()
            Updater.check(this)
        }
    }

    override fun onStop() {
        super.onStop()
        visible = false
        // Свернули — самое время обновиться.
        thread(name = "update-install") { Updater.installQuietly(applicationContext) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onDestroy() {
        if (isFinishing) Updater.listener = null
        channel?.setMethodCallHandler(null)
        super.onDestroy()
    }

    companion object {
        /** Приложение на экране — ставить обновление нельзя, оно закроет его на глазах. */
        @Volatile var visible = false
    }
}
