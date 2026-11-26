package com.blainemiller.blip

import android.content.Context
import android.content.SharedPreferences

/**
 * Settings and the few facts the home-screen widgets show (the iPhone app's App Group store).
 * Every widget fact carries the time it was measured, so a widget never passes off stale numbers.
 */
class Store(context: Context) {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences("blip", Context.MODE_PRIVATE)

    var speedServerPublic: Boolean
        get() = prefs.getBoolean("speedPublic", true)
        set(v) = prefs.edit().putBoolean("speedPublic", v).apply()

    var selfHostedUrl: String
        get() = prefs.getString("selfHostedUrl", "").orEmpty()
        set(v) = prefs.edit().putString("selfHostedUrl", v.trim()).apply()

    var pingTarget: String
        get() = prefs.getString("pingTarget", "1.1.1.1").orEmpty().ifBlank { "1.1.1.1" }
        set(v) = prefs.edit().putString("pingTarget", v.trim()).apply()

    // --- widget facts ------------------------------------------------------------------------

    fun writeDevice(storageTotal: Long, storageFree: Long, thermal: Int, battery: Double?) {
        prefs.edit()
            .putLong("w.storageTotal", storageTotal)
            .putLong("w.storageFree", storageFree)
            .putInt("w.thermal", thermal)
            .putFloat("w.battery", (battery ?: -1.0).toFloat())
            .putLong("w.deviceAt", System.currentTimeMillis())
            .apply()
    }

    data class DeviceFact(val storageTotal: Long, val storageFree: Long, val thermal: Int, val battery: Double?, val at: Long)

    fun device(): DeviceFact? {
        val at = prefs.getLong("w.deviceAt", 0)
        if (at == 0L) return null
        return DeviceFact(
            prefs.getLong("w.storageTotal", 0), prefs.getLong("w.storageFree", 0), prefs.getInt("w.thermal", 0),
            prefs.getFloat("w.battery", -1f).toDouble().takeIf { it >= 0 }, at,
        )
    }

    fun writeSpeed(down: Double, up: Double?, interfaceType: String, atSeconds: Long) {
        prefs.edit()
            .putFloat("w.down", down.toFloat())
            .putFloat("w.up", (up ?: -1.0).toFloat())
            .putString("w.speedIface", interfaceType)
            .putLong("w.speedAt", atSeconds * 1000)
            .apply()
    }

    data class SpeedFact(val down: Double, val up: Double?, val iface: String, val at: Long)

    fun speed(): SpeedFact? {
        val at = prefs.getLong("w.speedAt", 0)
        if (at == 0L) return null
        return SpeedFact(
            prefs.getFloat("w.down", 0f).toDouble(), prefs.getFloat("w.up", -1f).toDouble().takeIf { it >= 0 },
            prefs.getString("w.speedIface", "").orEmpty(), at,
        )
    }

    fun writeBench(score: Double, best: Double?, atSeconds: Long) {
        prefs.edit()
            .putFloat("w.bench", score.toFloat())
            .putFloat("w.benchBest", (best ?: -1.0).toFloat())
            .putLong("w.benchAt", atSeconds * 1000)
            .apply()
    }

    data class BenchFact(val score: Double, val best: Double?, val at: Long)

    fun bench(): BenchFact? {
        val at = prefs.getLong("w.benchAt", 0)
        if (at == 0L) return null
        return BenchFact(prefs.getFloat("w.bench", 0f).toDouble(), prefs.getFloat("w.benchBest", -1f).toDouble().takeIf { it > 0 }, at)
    }
}
