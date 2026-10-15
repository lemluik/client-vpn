package com.clientvpn.client_vpn

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

    private var attachedOnce = false

    fun subscribe(sink: (method: String, argument: Any) -> Unit) {
        // Первый Activity создаётся до запуска Dart: транслировать ему статус
        // некуда, обработчик на стороне Flutter ещё не зарегистрирован.
        val replay = attachedOnce
        attachedOnce = true
        this.sink = sink
        if (replay) sink("status", lastStatus)
    }

    fun unsubscribe() {
        sink = null
    }

    fun log(line: String) {
        sink?.invoke("log", line)
    }

    fun status(running: Boolean) {
        lastStatus = running
        sink?.invoke("status", running)
    }
}
