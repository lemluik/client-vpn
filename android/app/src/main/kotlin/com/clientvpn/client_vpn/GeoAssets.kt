package com.clientvpn.client_vpn

import android.content.Context
import java.io.File
import java.security.MessageDigest

/**
 * Geo-базы `geoip.dat` и `geosite.dat` — без них любое правило вида
 * `geoip:ru` или `geosite:yandex` роняет ядро ещё на проверке конфига.
 *
 * Из APK читать нельзя: ядро берёт базы из каталога, указанного в
 * `XRAY_LOCATION_ASSET`, поэтому при первом запуске файлы копируются в filesDir
 * и сверяются с контрольными суммами из манифеста, который кладёт рядом
 * скрипт загрузки.
 */
object GeoAssets {
    private const val ASSET_DIR = "geo"
    private const val MANIFEST = "geo-manifest.txt"
    val NAMES = listOf("geoip.dat", "geosite.dat")

    /** Каталог для переменной окружения ядра. */
    fun assetDir(context: Context): File = context.filesDir

    /**
     * Устанавливает недостающие базы. Возвращает текст ошибки для пользователя
     * или null, если базы на месте.
     */
    fun ensure(context: Context): String? {
        val manifest = readManifest(context)
            ?: return "Geo-базы не установлены: в сборке нет $MANIFEST — " +
                "выполните bash scripts/download_xray_android.sh и пересоберите APK"

        for (name in NAMES) {
            val entry = manifest[name] ?: return "В $MANIFEST нет записи для $name"
            val target = File(assetDir(context), name)
            if (target.length() == entry.bytes) continue
            val failure = install(context, name, target, entry.sha256)
            if (failure != null) return failure
        }
        return null
    }

    private class Entry(val sha256: String, val bytes: Long)

    /** Строка манифеста: `сумма  имя_файла  размер`. */
    private fun readManifest(context: Context): Map<String, Entry>? = try {
        context.assets.open("$ASSET_DIR/$MANIFEST").bufferedReader().useLines { lines ->
            lines.mapNotNull { line ->
                val parts = line.trim().split(Regex("\\s+"))
                if (parts.size < 2) return@mapNotNull null
                val size = if (parts.size > 2) parts[2].toLongOrNull() ?: -1L else -1L
                parts[1] to Entry(parts[0], size)
            }.toMap()
        }
    } catch (e: Exception) {
        null
    }

    private fun install(context: Context, name: String, target: File, sha256: String): String? {
        val bytes = try {
            context.assets.open("$ASSET_DIR/$name").use { it.readBytes() }
        } catch (e: Exception) {
            return "Geo-база $name не найдена в сборке — пересоберите APK " +
                "после scripts/download_xray_android.sh"
        }

        val digest = MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
        if (digest != sha256) {
            return "Geo-база $name не прошла проверку контрольной суммы"
        }

        // Запись через временный файл и переименование: обрезанная копия
        // (не хватило места, приложение убили в процессе copy) не должна
        // остаться под итоговым именем.
        val temp = File(target.parentFile, "$name.tmp")
        return try {
            temp.writeBytes(bytes)
            if (!temp.renameTo(target)) return "Не удалось установить $name в ${target.parent}"
            null
        } catch (e: Exception) {
            "Не удалось установить $name: ${e.message}"
        }
    }
}
