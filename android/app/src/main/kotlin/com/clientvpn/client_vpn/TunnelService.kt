package com.clientvpn.client_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.Os
import android.system.OsConstants
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
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
        const val APPS_FILE = "tunnel-apps.txt"

        /** Метка свежести конфига: её пишет Dart после каждой сборки конфига
         *  подключения. Плитка поднимает туннель нативно только пока метка
         *  есть — смена профиля, региона, пресета или правил её снимает. */
        const val FRESH_MARKER = "tunnel-config.fresh"
        const val XRAY_LIB = "libxray.so"

        /** Ставится плиткой перед тем, как отдать сервису команду: по нему
         *  статус понимает, что команду отдала оболочка, а не интерфейс. */
        @Volatile
        var fromShell = false

        /** Конфиг на диске есть и он свежий — поднимать туннель из оболочки можно. */
        fun canStartFromShell(context: Context): Boolean {
            val dir = context.filesDir
            return File(dir, TUNNEL_CONFIG).exists() && File(dir, FRESH_MARKER).exists()
        }

        private const val SESSION = "Нейтрино"
        private const val CHANNEL_ID = "tunnel"
        private const val NOTIFICATION_ID = 1
        private const val MTU = 1500
        private const val TUN_FD_ENV = "xray.tun.fd"
        private const val ASSET_ENV = "XRAY_LOCATION_ASSET"

        /** Интерфейс туннеля VpnService: `tun0`, `tun1`… — но не `tunl0`
         *  (это IP-туннель ядра, к нашему VPN отношения не имеет). */
        private val TUN_IFACE = Regex("tun\\d+")

        /** Период обновления уведомления со скоростью, мс. */
        private const val TRAFFIC_INTERVAL_MS = 1000L
    }

    private var process: Process? = null
    private var tunnel: ParcelFileDescriptor? = null
    private var logReader: Thread? = null

    /** Замер трафика туннеля: счётчики `/proc/net/dev` на старте сессии
     *  (база) и на прошлом тике (для скорости). */
    private var trafficTimer: ScheduledExecutorService? = null
    private var baseRx = 0L
    private var baseTx = 0L
    private var lastRx = 0L
    private var lastTx = 0L
    private var lastTs = 0L

    @Volatile
    private var stopping = false

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Признак читается один раз: следующий вызов приходит из интерфейса.
        val byShell = fromShell
        fromShell = false
        when (intent?.action) {
            ACTION_START -> startTunnel(byShell)
            ACTION_STOP -> {
                stopTunnel(byShell)
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

    private fun startTunnel(byShell: Boolean = false) {
        if (process != null) {
            TunnelBus.log("Туннель уже поднят")
            // Статус публикуется и здесь: интерфейс мог открыться заново и
            // спросить разрешение именно этим вызовом.
            TunnelBus.status(true, byShell, this)
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

        // Правила «это приложение идёт напрямую» (R2.3). Ядро Xray не умеет
        // условие по имени пакета — замер 16.10.2026: правило с `packageName`
        // отвергается на старте («this rule has no effective fields»), поэтому
        // отбор делает сам VpnService списком исключений.
        for (app in excludedApps()) {
            try {
                builder.addDisallowedApplication(app)
            } catch (e: Exception) {
                // Приложение могло быть удалено после выбора: туннель из-за
                // одного имени поднимать неверно.
                TunnelBus.log("Не исключено из туннеля $app: ${e.message}")
            }
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
            launchXray(config, byShell)
        } catch (e: Exception) {
            closeTunnel()
            fail("Не удалось запустить ядро: ${e.message}")
        }
    }

    /** Имена пакетов, выбранные пользователем как «напрямую». Одна строка на
     *  приложение; файл пишет Dart перед подключением. */
    private fun excludedApps(): List<String> {
        val file = File(filesDir, APPS_FILE)
        if (!file.exists()) return emptyList()
        return file.readLines()
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != packageName }
    }

    private fun launchXray(config: File, byShell: Boolean) {
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
        TunnelBus.status(true, byShell, this)
        startTrafficMonitor()
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

    private fun stopTunnel(byShell: Boolean = false) {
        stopping = true
        stopTrafficMonitor()
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
        TunnelBus.status(false, byShell, this)
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
        TunnelBus.status(false, false, this)
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

        startForeground(
            NOTIFICATION_ID,
            notificationBuilder()
                .setContentTitle(SESSION)
                .setContentText("Трафик идёт через туннель")
                .build(),
        )
    }

    /** База уведомления: иконка, тап открывает приложение, неснимаемое. */
    private fun notificationBuilder(): Notification.Builder {
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
        return builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(open)
            .setOngoing(true)
    }

    /** Обновляет уведомление текущей скоростью и трафиком за сессию.
     *  В свёрнутом виде — строка скорости, в развёрнутом — скорость и сессия. */
    private fun postNotification(upSpeed: Double, downSpeed: Double, sessUp: Long, sessDown: Long) {
        val speedLine = "↑ ${formatSpeed(upSpeed)} · ↓ ${formatSpeed(downSpeed)}"
        val sessionLine =
            "За сессию: ↑ ${formatBytes(sessUp.toDouble())} · ↓ ${formatBytes(sessDown.toDouble())}"
        getSystemService(NotificationManager::class.java).notify(
            NOTIFICATION_ID,
            notificationBuilder()
                .setContentTitle(SESSION)
                .setContentText(speedLine)
                .setStyle(Notification.BigTextStyle().bigText("$speedLine\n$sessionLine"))
                .build(),
        )
    }

    // ---- Замер трафика туннеля ----

    private fun startTrafficMonitor() {
        stopTrafficMonitor()
        val counters = readTunCounters()
        baseRx = counters?.first ?: 0L
        baseTx = counters?.second ?: 0L
        lastRx = baseRx
        lastTx = baseTx
        lastTs = SystemClock.elapsedRealtime()
        trafficTimer = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "tun-traffic").apply { isDaemon = true }
        }.also { executor ->
            executor.scheduleAtFixedRate(
                {
                    // Один сбой замера не должен ронять поток расписания.
                    try {
                        trafficTick()
                    } catch (e: Exception) {
                    }
                },
                TRAFFIC_INTERVAL_MS,
                TRAFFIC_INTERVAL_MS,
                TimeUnit.MILLISECONDS,
            )
        }
    }

    private fun stopTrafficMonitor() {
        trafficTimer?.shutdownNow()
        trafficTimer = null
    }

    private fun trafficTick() {
        val counters = readTunCounters() ?: return
        val rx = counters.first
        val tx = counters.second
        val now = SystemClock.elapsedRealtime()
        val seconds = (now - lastTs) / 1000.0
        val downSpeed = if (seconds > 0) (rx - lastRx).coerceAtLeast(0) / seconds else 0.0
        val upSpeed = if (seconds > 0) (tx - lastTx).coerceAtLeast(0) / seconds else 0.0
        lastRx = rx
        lastTx = tx
        lastTs = now
        postNotification(upSpeed, downSpeed, (tx - baseTx).coerceAtLeast(0), (rx - baseRx).coerceAtLeast(0))
    }

    /** Байты принятого (rx — входящий) и отправленного (tx — исходящий)
     *  ядром xray через сокеты. SELinux не даёт читать `/proc/net/dev` из
     *  песочницы приложения, поэтому берём счётчики по UID через
     *  TrafficStats — xray работает как дочерний процесс с тем же UID. */
    private fun readTunCounters(): Pair<Long, Long>? {
        return try {
            val uid = android.os.Process.myUid()
            val rx = android.net.TrafficStats.getUidRxBytes(uid)
            val tx = android.net.TrafficStats.getUidTxBytes(uid)
            if (rx < 0 || tx < 0) null else rx to tx
        } catch (e: Exception) {
            null
        }
    }

    private fun formatBytes(bytes: Double): String {
        if (bytes < 1024) return "${bytes.toLong()} Б"
        val kb = bytes / 1024
        if (kb < 1024) return String.format("%.1f КБ", kb)
        val mb = kb / 1024
        if (mb < 1024) return String.format("%.1f МБ", mb)
        return String.format("%.2f ГБ", mb / 1024)
    }

    private fun formatSpeed(bytesPerSecond: Double): String =
        "${formatBytes(bytesPerSecond)}/с"
}
