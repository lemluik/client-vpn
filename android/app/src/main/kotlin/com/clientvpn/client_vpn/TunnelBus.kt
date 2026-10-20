package com.clientvpn.client_vpn

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.service.quicksettings.TileService

/**
 * Мост событий фонового сервиса к интерфейсу.
 *
 * Туннель живёт дольше одного вызова MethodChannel, поэтому журнал и статус
 * идут через общую шину, на которую подписывается MainActivity.
 */
object TunnelBus {
    @Volatile
    private var sink: ((method: String, argument: Any) -> Unit)? = null

    /**
     * Последний статус, известный сервису. Он переживает закрытие экрана,
     * поэтому новый Activity получает его при подписке, а не ждёт ближайшего
     * события: без этого UI стартует с «Отключён» при поднятом туннеле.
     */
    @Volatile
    var lastStatus = false
        private set

    /** Тем ли событием статус поменялся, что команду отдала оболочка. */
    @Volatile
    var lastByShell = false
        private set

    private var attachedOnce = false

    fun subscribe(sink: (method: String, argument: Any) -> Unit) {
        // Первый Activity создаётся до запуска Dart: транслировать ему статус
        // некуда, обработчик на стороне Flutter ещё не зарегистрирован.
        val replay = attachedOnce
        attachedOnce = true
        this.sink = sink
        if (replay) sink("status", payload(lastStatus, lastByShell))
    }

    fun unsubscribe() {
        sink = null
    }

    fun log(line: String) {
        sink?.invoke("log", line)
    }

    fun status(running: Boolean, byShell: Boolean = false, context: Context? = null) {
        lastStatus = running
        lastByShell = byShell
        sink?.invoke("status", payload(running, byShell))
        context?.let { refreshTile(it) }
    }

    private fun payload(running: Boolean, byShell: Boolean): Map<String, Boolean> =
        mapOf("running" to running, "byShell" to byShell)

    /**
     * Просит оболочку переспросить состояние плитки. Единственное место, откуда
     * это делается: подписываться на шину самой плитке нельзя — у неё один
     * подписчик, и интерфейс потерял бы события.
     */
    fun refreshTile(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            TileService.requestListeningState(
                context.applicationContext,
                ComponentName(context, TunnelTileService::class.java),
            )
        } catch (e: Exception) {
            // Плитка ещё не добавлена пользователем — переспрашивать некого.
        }
    }
}
