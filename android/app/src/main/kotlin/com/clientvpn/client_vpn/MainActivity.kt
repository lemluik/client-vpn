package com.clientvpn.client_vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "client_vpn/tunnel"
        private const val APP_CHANNEL = "client_vpn/app"
        private const val USER_CONFIG = "user-config.json"
        private const val CONSENT_REQUEST = 4242
    }

    private lateinit var channel: MethodChannel
    private var pendingConsent: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        TunnelBus.sink = { method, argument ->
            runOnUiThread { channel.invokeMethod(method, argument) }
        }
    }

    override fun onDestroy() {
        TunnelBus.sink = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "validate" -> validate(call.arguments as? String, result)
                "start" -> start(call.arguments as? String, result)
                "stop" -> stop(result)
                else -> result.notImplemented()
            }
        }

        // Автозапуск: значение читает и пишет система, Dart только показывает переключатель.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAutoStart" -> result.success(AutoStart.isOn(this))
                    "setAutoStart" -> {
                        val value = call.arguments as? Boolean
                        if (value == null) {
                            result.error("bad_argument", "Не передан флаг автозапуска", null)
                        } else {
                            AutoStart.set(this, value)
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Прогоняет конфиг пользователя через `xray run -test` — как на десктопе. */
    private fun validate(userConfig: String?, result: MethodChannel.Result) {
        if (userConfig == null) {
            result.error("bad_argument", "Не передан конфиг", null)
            return
        }
        Thread {
            val failure = try {
                testConfig(userConfig)
            } catch (e: Exception) {
                e.message ?: "неизвестная ошибка"
            }
            runOnUiThread {
                if (failure == null) result.success(null)
                else result.error("invalid_config", failure, null)
            }
        }.apply { isDaemon = true }.start()
    }

    /** Возвращает текст ошибки или null, если конфиг принят ядром. */
    private fun testConfig(userConfig: String): String? {
        val file = File(filesDir, USER_CONFIG)
        file.writeText(userConfig)

        val xray = File(applicationInfo.nativeLibraryDir, TunnelService.XRAY_LIB)
        if (!xray.exists()) return "ядро не найдено в ${xray.parent}"
        xray.setExecutable(true)

        // Проверка конфига с geo-правилами без баз падает на чтении geosite.dat:
        // ядро искало бы файл в рабочем каталоге.
        GeoAssets.ensure(this)?.let { return it }

        val process = ProcessBuilder(
            xray.absolutePath,
            "run",
            "-test",
            "-config",
            file.absolutePath,
        )
            .directory(filesDir)
            .redirectErrorStream(true)
            .apply { environment()["XRAY_LOCATION_ASSET"] = GeoAssets.assetDir(this@MainActivity).absolutePath }
            .start()

        val output = process.inputStream.bufferedReader().readText()
        if (!process.waitFor(30, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            return "проверка не завершилась за 30 секунд"
        }
        return if (process.exitValue() == 0) {
            null
        } else {
            output.trim().ifEmpty { "код ${process.exitValue()}" }
        }
    }

    private fun start(tunConfig: String?, result: MethodChannel.Result) {
        if (tunConfig == null) {
            result.error("bad_argument", "Не передан конфиг туннеля", null)
            return
        }
        File(filesDir, TunnelService.TUNNEL_CONFIG).writeText(tunConfig)

        val consent = VpnService.prepare(this)
        if (consent != null) {
            pendingConsent = result
            try {
                startActivityForResult(consent, CONSENT_REQUEST)
            } catch (e: Exception) {
                pendingConsent = null
                result.error("consent_failed", e.message, null)
            }
            return
        }

        launchTunnel()
        result.success(true)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != CONSENT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val pending = pendingConsent
        pendingConsent = null
        val granted = resultCode == Activity.RESULT_OK
        if (granted) launchTunnel()
        pending?.success(granted)
    }

    private fun stop(result: MethodChannel.Result) {
        startService(
            Intent(this, TunnelService::class.java).setAction(TunnelService.ACTION_STOP),
        )
        result.success(null)
    }

    private fun launchTunnel() {
        val intent = Intent(this, TunnelService::class.java)
            .setAction(TunnelService.ACTION_START)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
