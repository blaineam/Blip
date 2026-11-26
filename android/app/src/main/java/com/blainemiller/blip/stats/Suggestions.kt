package com.blainemiller.blip.stats

import com.blainemiller.blip.L

/**
 * Honest, actionable suggestions — shown only when a signal Android actually reports fires.
 * Nothing speculative, nothing scolding (the iPhone app's rules, in Android's terms).
 */
object Suggestions {
    enum class Kind { Storage, Thermal, Power, Data, Memory }

    data class Item(val id: String, val kind: Kind, val text: String)

    fun evaluate(s: DeviceSnapshot): List<Item> {
        val out = mutableListOf<Item>()
        if (s.storagePercentUsed > 92) {
            out += Item(
                "storage", Kind.Storage,
                L.tf("Storage is nearly full (%@ left). Android slows down and updates fail when space runs out — clear app caches or move photos and videos off in Settings › Storage.", Fmt.bytes(s.storageFree)),
            )
        }
        if (s.thermalState >= 2) {
            out += Item(
                "thermal", Kind.Thermal,
                L.tf("The device is running %@ — performance is being throttled. Take it off the charger or out of the sun; skip benchmarking until nominal.", L.t(s.thermalLabel).lowercase()),
            )
        }
        val level = s.batteryLevel
        if (s.powerSave && s.batteryState == "Charging" && level != null && level > 0.8) {
            out += Item(
                "saver", Kind.Power,
                L.t("Battery Saver is still on while charging above 80% — background work and performance stay reduced until you switch it off."),
            )
        }
        if (s.dataSaver) {
            out += Item(
                "datasaver", Kind.Data,
                L.t("Data Saver is on — background data, quality and sync are being limited. Intentional? It's in Settings › Network & internet."),
            )
        }
        if (s.lowMemory || (s.memoryAvailable in 1 until (500L shl 20))) {
            out += Item(
                "memory", Kind.Memory,
                L.tf("Memory available to apps is low (%@). Heavy apps may relaunch from scratch; closing camera- and game-class apps you're done with helps.", Fmt.memory(s.memoryAvailable)),
            )
        }
        return out
    }
}
