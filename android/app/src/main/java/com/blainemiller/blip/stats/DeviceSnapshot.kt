package com.blainemiller.blip.stats

/**
 * What Android lets an ordinary app know about the device, with no runtime permission: the same
 * honest-subset idea as the iPhone app. Android 8+ hides other apps' CPU time (/proc/stat), so
 * the CPU card shows core clocks against their maximum — what the scheduler is actually asking of
 * the chip — rather than an invented usage figure.
 */
data class Cluster(val cores: Int, val curMhz: Int?, val maxMhz: Int)

data class DeviceSnapshot(
    // CPU
    val coresTotal: Int = 0,
    val coresPerformance: Int = 0,
    val coresEfficiency: Int = 0,
    val clusters: List<Cluster> = emptyList(),
    /** Average current clock as % of each core's maximum; null where the kernel hides cpufreq. */
    val clockPercent: Double? = null,
    val load: List<Double>? = null,
    val soc: String = "",
    val abi: String = "",
    // Memory
    val memoryTotal: Long = 0,
    val memoryAvailable: Long = 0,
    val memoryThreshold: Long = 0,
    val lowMemory: Boolean = false,
    val memoryCached: Long? = null,
    val swapTotal: Long? = null,
    val swapFree: Long? = null,
    val appFootprint: Long = 0,
    // Storage
    val storageTotal: Long = 0,
    val storageFree: Long = 0,
    // Battery
    val batteryLevel: Double? = null,
    val batteryState: String = "Unknown",
    val plugged: String? = null,
    val batteryHealth: String? = null,
    val batteryTempC: Double? = null,
    val batteryVoltageMv: Int? = null,
    val batteryCurrentMa: Int? = null,
    val batteryChargeMah: Int? = null,
    val batteryCycles: Int? = null,
    val batteryTechnology: String? = null,
    val powerSave: Boolean = false,
    // Thermal
    /** 0 nominal … 3 critical (the Mac/iPhone scale), from PowerManager's thermal status. */
    val thermalState: Int = 0,
    val thermalStatusRaw: Int = 0,
    /** Forecast headroom (1.0 = throttling starts), Android 11+. */
    val thermalHeadroom: Double? = null,
    // Network
    val interfaceType: String = "Offline",
    val interfaceName: String? = null,
    val metered: Boolean = false,
    val dataSaver: Boolean = false,
    val vpnActive: Boolean = false,
    val localIPs: List<String> = emptyList(),
    val dns: List<String> = emptyList(),
    val gateway: String? = null,
    val privateDns: String? = null,
    val downKbps: Int? = null,
    val upKbps: Int? = null,
    val wifiRssi: Int? = null,
    val wifiLinkMbps: Int? = null,
    val wifiFrequencyMhz: Int? = null,
    // Device
    val manufacturer: String = "",
    val model: String = "",
    val marketingName: String = "",
    val androidVersion: String = "",
    val sdk: Int = 0,
    val securityPatch: String = "",
    val uptimeMs: Long = 0,
    val awakeMs: Long = 0,
    val bootMillis: Long = 0,
) {
    val storageUsed: Long get() = (storageTotal - storageFree).coerceAtLeast(0)
    val storagePercentUsed: Double get() = if (storageTotal > 0) storageUsed * 100.0 / storageTotal else 0.0
    val memoryUsed: Long get() = (memoryTotal - memoryAvailable).coerceAtLeast(0)
    val memoryPercentUsed: Double get() = if (memoryTotal > 0) memoryUsed * 100.0 / memoryTotal else 0.0
    val thermalLabel: String
        get() = when (thermalState) {
            0 -> "Nominal"
            1 -> "Fair"
            2 -> "Serious"
            else -> "Critical"
        }

    companion object {
        /** PowerManager THERMAL_STATUS_* (0 none … 6 shutdown) → the Mac/iPhone 0–3 scale. */
        fun thermalLevel(status: Int): Int = when (status) {
            0 -> 0
            1, 2 -> 1
            3 -> 2
            else -> 3
        }
    }
}
