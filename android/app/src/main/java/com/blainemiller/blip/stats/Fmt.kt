package com.blainemiller.blip.stats

import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToLong

/** Number formatting shared by every screen (same conventions as the iPhone app). */
object Fmt {
    private val units = listOf("bytes", "KB", "MB", "GB", "TB", "PB")

    /** Storage: decimal units, like Android's own Settings › Storage ("128 GB"). */
    fun bytes(n: Long): String = scaled(n.toDouble(), 1000.0)

    /** RAM: binary quantity in the marketed style — 12 GiB reads "12 GB". */
    fun memory(n: Long): String = scaled(n.toDouble(), 1024.0)

    private fun scaled(v: Double, base: Double): String {
        var x = abs(v)
        var i = 0
        while (x >= base && i < units.lastIndex) {
            x /= base
            i++
        }
        val sign = if (v < 0) "-" else ""
        return when {
            i == 0 -> "$sign${x.roundToLong()} ${units[0]}"
            x >= 100 -> "$sign${x.roundToLong()} ${units[i]}"
            x >= 10 -> sign + String.format(Locale.getDefault(), "%.1f %s", x, units[i])
            else -> sign + String.format(Locale.getDefault(), "%.2f %s", x, units[i])
        }
    }

    fun uptime(ms: Long): String {
        val t = ms / 1000
        val days = t / 86400
        val hours = (t % 86400) / 3600
        val mins = (t % 3600) / 60
        return when {
            days > 0 -> "${days}d ${hours}h"
            hours > 0 -> "${hours}h ${mins}m"
            else -> "${mins}m"
        }
    }

    fun mbps(v: Double): String = when {
        v >= 100 -> String.format(Locale.getDefault(), "%.0f Mbps", v)
        v >= 10 -> String.format(Locale.getDefault(), "%.1f Mbps", v)
        else -> String.format(Locale.getDefault(), "%.2f Mbps", v)
    }

    fun ms(v: Double?): String = v?.let { String.format(Locale.getDefault(), "%.1f ms", it) } ?: "—"

    fun score(v: Double): String = String.format(Locale.getDefault(), "%,d", v.roundToLong())

    fun percent(v: Double): String = "${v.roundToLong()}%"

    fun mhz(v: Int): String = if (v >= 1000) String.format(Locale.getDefault(), "%.2f GHz", v / 1000.0) else "$v MHz"

    fun date(unixSeconds: Long): String =
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(unixSeconds * 1000))
}
