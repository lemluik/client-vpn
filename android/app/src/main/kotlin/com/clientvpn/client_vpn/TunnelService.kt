package com.clientvpn.client_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

/**
 * Туннель Android.
 *
 * Ядро Xray запускается дочерним процессом из каталога нативных библиотек
 * (единственное место, откуда на Android 10+ разрешено исполнять файлы)
 * и получает дескриптор туннеля через переменную окружения `xray.tun.fd` —
 * так это делает proxy/tun/tun_android.go в Xray-core.
 */
class TunnelService : VpnService() {

    companion object {
        const val ACTION_START = "com.clientvpn.client_vpn.START"
        const val ACTION_STOP = "com.clientvpn.client_vpn.STOP"
        const val TUNNEL_CONFIG = "tunnel-config.json"
        const val XRAY_LIB = "libxray.so"

        private const val SESSION = "КлиентВПН"
        private const val CHANNEL_ID = "tunnel"
        private const val NOTIFICATION_ID = 1
        private const val MTU = 1500
        private const val TUN_FD_ENV = "xray.tun.fd"
        private const val ASSET_ENV = "XRAY_LOCATION_ASSET"
    }

    private var process: Process? = null
    private var tunnel: ParcelFileDescriptor? = null
    private var logReader: Thread? = null

    @Volatile
    private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startTunnel()
            ACTION_STOP -> {
                stopTunnel()
                stopSelf()
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopTunnel()
        stopSelf()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun startTunnel() {
        if (process != null) {
            TunnelBus.log("Туннель уже поднят")
            // Статус публикуется и здесь: интерфейс мог открыться заново и
            // спросить разрешение именно этим вызовом.
            TunnelBus.status(true)
            return
        }

        // Уведомление обязано появиться раньше любых проверок: сервис
        // запущен через startForegroundService и на это есть пять секунд.
        showNotification()

        val config = File(filesDir, TUNNEL_CONFIG)
        if (!config.exists()) {
            fail("Конфиг туннеля не найден — выберите config.json заново")
            return
        }

        val builder = Builder()
            .setSession(SESSION)
            .setMtu(MTU)
            .addAddress("172.19.0.1", 24)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")

        // IPv6 забираем в туннель даже без поддержки на выходе: иначе он
        // уйдёт напрямую мимо прокси.
        try {
            builder.addAddress("fd00:c0fe::1", 124).addRoute("::", 0)
        } catch (e: Exception) {
            TunnelBus.log("IPv6 в туннель не добавлен: ${e.message}")
        }

        // Свой процесс исключён из туннеля, иначе исходящее плечо ядра
        // замыкалось бы само на себя.
        try {
            builder.addDisallowedApplication(packageName)
        } catch (e: Exception) {
            fail("Не удалось исключить приложение из туннеля: ${e.message}")
            return
        }

        val descriptor = try {
            builder.establish()
        } catch (e: Exception) {
            fail("Android не поднял туннель: ${e.message}")
            return
        }
        if (descriptor == null) {
            fail("Android не поднял туннель")
            return
        }

        val fd = descriptor.detachFd()
        tunnel = ParcelFileDescriptor.adoptFd(fd)
        try {
            // libcore закрывает в ребёнке все дескрипторы кроме stdio, поэтому
            // туннель передаётся как stdin: fd 0 ребёнок сохраняет всегда.
            Os.dup2(tunnel!!.fileDescriptor, 0)
            launchXray(config)
        } catch (e: Exception) {
            closeTunnel()
            fail("Не удалось запустить ядро: ${e.message}")
        }
    }

    private fun launchXray(config: File) {
        val xray = File(applicationInfo.nativeLibraryDir, XRAY_LIB)
        if (!xray.exists()) {
            throw IllegalStateException("ядро не найдено в ${xray.parent}")
        }
        xray.setExecutable(true)

        // Без баз правило `geoip:ru` роняет ядро на старте, а не на проверке:
        // ошибки конфигурации пользователь увидел бы как «не подключается».
        GeoAssets.ensure(this)?.let { throw IllegalStateException(it) }

        val launch = ProcessBuilder(xray.absolutePath, "run", "-config", config.absolutePath)
            .directory(filesDir)
            .redirectErrorStream(true)
            .redirectInput(ProcessBuilder.Redirect.INHERIT)
        launch.environment()[TUN_FD_ENV] = "0"
        launch.environment()[ASSET_ENV] = GeoAssets.assetDir(this).absolutePath

        val started = launch.start()
        process = started
        readLogs(started)

        Thread({
            val code = try {
                started.waitFor()
            } catch (e: InterruptedException) {
                return@Thread
            }
            if (!stopping) {
                TunnelBus.log("Ядро завершилось (код $code)")
                stopTunnel()
            }
        }, "xray-exit").apply { isDaemon = true }.start()

        TunnelBus.log("Туннель поднят, ядро запущено")
        TunnelBus.status(true)
    }

    private fun readLogs(started: Process) {
        logReader = Thread({
            try {
                BufferedReader(InputStreamReader(started.inputStream)).use { reader ->
                    var line = reader.readLine()
                    while (line != null) {
                        if (line.isNotBlank()) TunnelBus.log(line)
                        line = reader.readLine()
                    }
                }
            } catch (e: Exception) {
                if (!stopping) TunnelBus.log("[ERR] журнал ядра: ${e.message}")
            }
        }, "xray-log").apply { isDaemon = true }.also { it.start() }
    }

    private fun stopTunnel() {
        stopping = true
        logReader?.interrupt()
        logReader = null

        process?.let { running ->
            try {
                running.destroy()
                if (!running.waitFor(3, TimeUnit.SECONDS)) running.destroyForcibly()
            } catch (e: Exception) {
                TunnelBus.log("[ERR] остановка ядра: ${e.message}")
            }
        }
        process = null
        closeTunnel()

        stopping = false
        TunnelBus.status(false)
    }

    private fun closeTunnel() {
        try {
            tunnel?.close()
        } catch (e: Exception) {
            TunnelBus.log("[ERR] закрытие туннеля: ${e.message}")
        } finally {
            tunnel = null
        }
        // stdin процесса был заменён туннелем — вернуть заглушку, иначе
        // следующие дочерние процессы получат закрытый fd 0.
        try {
            val devNull = Os.open("/dev/null", OsConstants.O_RDWR, 0)
            Os.dup2(devNull, 0)
            Os.close(devNull)
        } catch (e: Exception) {
            TunnelBus.log("[ERR] восстановление stdin: ${e.message}")
        }
    }

    private fun fail(message: String) {
        TunnelBus.log("[ERR] $message")
        TunnelBus.status(false)
        stopSelf()
    }

    private fun showNotification() {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Туннель",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) }
            manager.createNotificationChannel(channel)
        }

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            flags,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        startForeground(
            NOTIFICATION_ID,
            builder
                .setContentTitle(SESSION)
                .setContentText("Трафик идёт через туннель")
                .setSmallIcon(R.drawable.ic_vpn_key)
                .setContentIntent(open)
                .setOngoing(true)
                .build(),
        )
    }
}
