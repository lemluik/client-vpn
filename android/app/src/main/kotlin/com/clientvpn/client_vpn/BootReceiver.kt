package com.clientvpn.client_vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Поднимает приложение после загрузки системы, когда пользователь согласился
 * на автозапуск. Туннель отсюда не запускается: конфиг готовит Dart, а согласия
 * на VPN-профиль из приёмника никто не подтвердит.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != QUICKBOOT &&
            action != QUICKBOOT_HTC
        ) {
            return
        }
        if (!AutoStart.isOn(context)) return

        val launch = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(launch)
        } catch (e: Exception) {
            // Android 10+ не разрешает показывать окно из фона: приложение
            // откроется, когда пользователь разблокирует телефон.
            Log.i("BootReceiver", "автозапуск отложен: ${e.message}")
        }
    }

    private companion object {
        const val QUICKBOOT = "android.intent.action.QUICKBOOT_POWERON"
        const val QUICKBOOT_HTC = "com.htc.intent.action.QUICKBOOT_POWERON"
    }
}
