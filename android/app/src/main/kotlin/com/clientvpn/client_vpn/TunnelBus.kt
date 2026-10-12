package com.clientvpn.client_vpn

/**
 * Мост событий фонового сервиса к интерфейсу.
 *
 * Туннель живёт дольше одного вызова MethodChannel, поэтому журнал и статус
 * идут через общую шину, на которую подписывается MainActivity.
 */
object TunnelBus {
    @Volatile
    var sink: ((method: String, argument: Any) -> Unit)? = null

    fun log(line: String) {
        sink?.invoke("log", line)
    }

    fun status(running: Boolean) {
        sink?.invoke("status", running)
    }
}
