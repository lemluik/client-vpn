package com.clientvpn.client_vpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import java.io.File
import java.net.NetworkInterface

/**
 * Плитка в шторке: подъём и остановка туннеля без открытия приложения.
 *
 * Состояние читается из двух источников — памяти сервиса и факта поднятого
 * туннельного интерфейса: `lastStatus` живёт в процессе и после его смерти
 * не переживает перезапуск оболочки.
 */
class TunnelTileService : TileService() {

    companion object {
        private const val CHANNEL = "client_vpn/tunnel"
        private const val TILE_ACTION = "com.clientvpn.client_vpn.action.TILE_CONNECT"
    }

    override fun onClick() {
        if (isTunnelUp()) {
            stopTunnel()
            return
        }
        if (!startFromShell()) openApp()
    }

    /** Оболочка переспрашивает состояние при каждом открытии шторки. */
    override fun onStartListening() {
        super.onStartListening()
        applyState()
    }

    private fun applyState() {
        val tile = qsTile ?: return
        val config = File(applicationContext.filesDir, TunnelService.TUNNEL_CONFIG)
        tile.state = when {
            !config.exists() -> Tile.STATE_UNAVAILABLE
            isTunnelUp() -> Tile.STATE_ACTIVE
            else -> Tile.STATE_INACTIVE
        }
        tile.label = getString(R.string.tile_label)
        tile.updateTile()
    }

    /** Путь А: сервис поднимается прямо из плитки, приложение не открывается. */
    private fun startFromShell(): Boolean {
        if (VpnService.prepare(applicationContext) != null) return false
        if (!TunnelService.canStartFromShell(applicationContext)) return false

        TunnelService.fromShell = true
        val intent = Intent(applicationContext, TunnelService::class.java)
            .setAction(TunnelService.ACTION_START)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            // Состояние перерисуется по событию шины: оболочка переспросит
            // плитку сама, см. TunnelBus.refreshTile.
            true
        } catch (e: Exception) {
            TunnelService.fromShell = false
            false
        }
    }

    /** Остановка тоже без открытия приложения. */
    private fun stopTunnel() {
        TunnelService.fromShell = true
        try {
            startService(
                Intent(applicationContext, TunnelService::class.java)
                    .setAction(TunnelService.ACTION_STOP),
            )
        } catch (e: Exception) {
            TunnelService.fromShell = false
            return
        }
        applyState()
    }

    /** Путь Б: активность получает признак «подключить из шторки». */
    private fun openApp() {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val intent = Intent(applicationContext, MainActivity::class.java)
            .setAction(TILE_ACTION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(applicationContext, 0, intent, flags)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                startActivityAndCollapse(pending)
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        } catch (e: Exception) {
            // Плитка не может поднять активность: открываем приложение обычно.
            try {
                startActivity(intent)
            } catch (ignored: Exception) {
            }
        }
    }

    /** Факт туннеля: интерфейс, который даёт VpnService, а не память процесса. */
    private fun isTunnelUp(): Boolean {
        if (TunnelBus.lastStatus) return true
        return try {
            NetworkInterface.getNetworkInterfaces()?.asSequence()
                ?.any { it.name == "tun0" && it.isUp } == true
        } catch (e: Exception) {
            false
        }
    }
}
