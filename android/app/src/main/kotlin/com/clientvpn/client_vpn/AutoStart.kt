package com.clientvpn.client_vpn

import android.content.Context

/**
 * Флаг автозапуска хранит система Android, а не Dart: его пишет экран настроек
 * через канал и читает загрузочный приёмник, когда Dart-процесса ещё нет.
 */
object AutoStart {
    private const val PREFS = "client_vpn.autostart"
    private const val KEY = "enabled"

    fun isOn(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)

    fun set(context: Context, value: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY, value)
            .apply()
    }
}
