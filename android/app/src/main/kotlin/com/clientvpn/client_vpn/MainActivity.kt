package com.clientvpn.client_vpn

import android.app.Activity
import android.app.StatusBarManager
import android.graphics.drawable.Icon
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.function.Consumer

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "client_vpn/tunnel"
        private const val DEEP_LINK_CHANNEL = "client_vpn/deep_link"
        private const val APP_CHANNEL = "client_vpn/app"
        private const val USER_CONFIG = "user-config.json"
        private const val CONSENT_REQUEST = 4242

        /** Тап по плитке, когда consent не дан или конфиг устарел: активность
         *  получает этот признак, а Dart забирает его одним чтением. */
        const val TILE_ACTION = "com.clientvpn.client_vpn.action.TILE_CONNECT"
    }

    private lateinit var channel: MethodChannel
    private var pendingConsent: MethodChannel.Result? = null

    private var deepLinkChannel: MethodChannel? = null
    private var pendingLink: String? = null

    /** Команда «подключить» из плитки: её забирает Dart ровно один раз. */
    private var pendingTileConnect = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLink = linkOf(intent)
        pendingTileConnect = intent?.action == TILE_ACTION
        TunnelBus.subscribe { method, argument ->
            runOnUiThread { channel.invokeMethod(method, argument) }
        }
    }

    override fun onDestroy() {
        TunnelBus.unsubscribe()
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
                "status" -> result.success(tileStatusPayload())
                "markTunnelFresh" -> markTunnelFresh(result)
                "takePendingConnect" -> {
                    val pending = pendingTileConnect
                    pendingTileConnect = false
                    result.success(pending)
                }
                "addTile" -> addTile(result)
                "setExcludedApps" -> setExcludedApps(call.arguments, result)
                "listApps" -> listApps(result)
                "openUrl" -> openUrl(call.arguments, result)
                else -> result.notImplemented()
            }
        }

        deepLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEEP_LINK_CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // Ссылка холодного старта забирается один раз, чтобы
                    // пересоздание движка не добавило её повторно.
                    "takePending" -> {
                        result.success(pendingLink)
                        pendingLink = null
                    }
                    else -> result.notImplemented()
                }
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

    /** Тап по ссылке, когда приложение уже живёт: singleTop даёт новый интент
     *  вместо второго экземпляра активности. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == TILE_ACTION) {
            // Отметку свежести ставит Dart перед подключением; здесь она уже
            // стоит, поэтому остаётся только поднять команду.
            pendingTileConnect = true
            return
        }
        val link = linkOf(intent) ?: return
        val deepLinks = deepLinkChannel
        if (deepLinks == null) {
            pendingLink = link
            return
        }
        runOnUiThread { deepLinks.invokeMethod("link", link) }
    }

    /** Наружу отдаём только стандартные схемы протоколов: MAIN-интент и
     *  прочие системные ссылки ссылкой подключения не являются. */
    private fun linkOf(intent: Intent?): String? {
        val data = intent?.data ?: return null
        return when (data.scheme) {
            "vless", "trojan", "vmess" -> data.toString()
            else -> null
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

    /** Список устанавливаемый вне туннеля приложений (R2.3): одна строка на
     *  имя пакета. Пишется до подключения — туннель читает его при поднятии. */
    private fun setExcludedApps(arguments: Any?, result: MethodChannel.Result) {
        val packages = (arguments as? List<*>)?.filterIsInstance<String>()
            ?: emptyList()
        try {
            File(filesDir, TunnelService.APPS_FILE)
                .writeText(packages.joinToString("\n"))
            result.success(null)
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    /** Приложения, которые пользователь может выбрать: те, у которых есть
     *  запускаемый экран, как их показывает система. */
    private fun listApps(result: MethodChannel.Result) {
        Thread {
            val output = try {
                val pm = packageManager
                val launcher = Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                val seen = LinkedHashMap<String, String>()
                for (info in pm.queryIntentActivities(launcher, 0)) {
                    val pkg = info.activityInfo.packageName
                    if (pkg != packageName) seen[pkg] = info.loadLabel(pm).toString()
                }
                seen.entries
                    .sortedBy { it.value.lowercase() }
                    .map { mapOf("package" to it.key, "name" to it.value) }
            } catch (e: Exception) {
                null
            }
            runOnUiThread {
                if (output != null) result.success(output)
                else result.error("apps_unavailable", "Список приложений недоступен", null)
            }
        }.apply { isDaemon = true }.start()
    }

    /** Открывает ссылку загрузки в системном браузере. Принимаем только
     *  `http`/`https`: адрес вводит пользователь на экране обновления. */
    private fun openUrl(arguments: Any?, result: MethodChannel.Result) {
        val raw = (arguments as? Map<*, *>)?.get("url") as? String
        val uri = try {
            Uri.parse(raw?.trim() ?: "")
        } catch (e: Exception) {
            null
        }
        if (uri == null || uri.host.isNullOrEmpty() ||
            uri.scheme != "http" && uri.scheme != "https") {
            result.error("bad_url", "Ссылка не похожа на адрес", null)
            return
        }
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE),
            )
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun start(tunConfig: String?, result: MethodChannel.Result) {
        if (tunConfig == null) {
            result.error("bad_argument", "Не передан конфиг туннеля", null)
            return
        }
        File(filesDir, TunnelService.TUNNEL_CONFIG).writeText(tunConfig)
        // Новый конфиг ещё не подтверждён поднятием: метку свежести вернёт
        // Dart, когда подключение действительно состоится.
        File(filesDir, TunnelService.FRESH_MARKER).delete()

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

    /** Метка свежести: её ставит Dart после успешного подключения, она же
     *  разрешает плитке поднимать туннель без открытия приложения. */
    private fun markTunnelFresh(result: MethodChannel.Result) {
        try {
            File(filesDir, TunnelService.FRESH_MARKER).writeText(
                "${System.currentTimeMillis()}\n",
            )
            result.success(null)
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    private fun tileStatusPayload(): Map<String, Boolean> =
        mapOf("running" to TunnelBus.lastStatus, "byShell" to TunnelBus.lastByShell)

    /** Системный запрос добавления плитки (API 33+); для более старых версий
     *  показываем текстовую инструкцию. */
    private fun addTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            Toast.makeText(
                this,
                getString(R.string.tile_instructions),
                Toast.LENGTH_LONG,
            ).show()
            result.success(false)
            return
        }
        val manager = getSystemService(StatusBarManager::class.java)
        if (manager == null) {
            result.success(false)
            return
        }
        try {
            manager.requestAddTileService(
                ComponentName(this, TunnelTileService::class.java),
                getString(R.string.tile_label),
                Icon.createWithResource(this, R.drawable.ic_tile_tunnel),
                Executor { command -> command.run() },
                Consumer<Int> { code ->
                    val added =
                        code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                        code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
                    runOnUiThread { result.success(added) }
                },
            )
        } catch (e: Exception) {
            result.success(false)
        }
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
