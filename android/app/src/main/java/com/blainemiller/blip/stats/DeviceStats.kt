package com.blainemiller.blip.stats

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.provider.Settings
import com.blainemiller.blip.core.Native
import java.io.File
import java.net.Inet4Address

/** Fixed-capacity ring of samples for the session sparklines. */
class SampleRing(private val capacity: Int = 90) {
    private val values = ArrayDeque<Double>()
    fun add(v: Double) {
        values.addLast(v)
        while (values.size > capacity) values.removeFirst()
    }
    fun toList(): List<Double> = values.toList()
}

/** Reads a [DeviceSnapshot]. Every source is a public API or a world-readable sysfs/procfs file. */
class DeviceStats(private val context: Context) {
    private val am = context.getSystemService(ActivityManager::class.java)
    private val pm = context.getSystemService(PowerManager::class.java)
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val bm = context.getSystemService(BatteryManager::class.java)

    val clockHistory = SampleRing()
    val memoryHistory = SampleRing()
    val thermalHistory = SampleRing()

    fun sample(): DeviceSnapshot {
        val cpu = cpu()
        val mem = memory()
        val snap = DeviceSnapshot(
            coresTotal = cpu.total,
            coresPerformance = cpu.performance,
            coresEfficiency = cpu.efficiency,
            clusters = cpu.clusters,
            clockPercent = cpu.clockPercent,
            load = Sys.loadAverage(),
            soc = soc(),
            abi = Build.SUPPORTED_ABIS.firstOrNull().orEmpty(),
            memoryTotal = mem.totalMem,
            memoryAvailable = mem.availMem,
            memoryThreshold = mem.threshold,
            lowMemory = mem.lowMemory,
            appFootprint = appFootprint(),
            powerSave = pm.isPowerSaveMode,
            thermalStatusRaw = pm.currentThermalStatus,
            thermalState = DeviceSnapshot.thermalLevel(pm.currentThermalStatus),
            thermalHeadroom = if (Build.VERSION.SDK_INT >= 30) {
                pm.getThermalHeadroom(10).toDouble().takeIf { !it.isNaN() && it > 0 }
            } else {
                null
            },
            manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() },
            model = Build.MODEL,
            marketingName = marketingName(),
            androidVersion = Build.VERSION.RELEASE,
            sdk = Build.VERSION.SDK_INT,
            securityPatch = Build.VERSION.SECURITY_PATCH,
            uptimeMs = SystemClock.elapsedRealtime(),
            awakeMs = SystemClock.uptimeMillis(),
            bootMillis = System.currentTimeMillis() - SystemClock.elapsedRealtime(),
        ).let(::withMeminfo).let(::withStorage).let(::withBattery).let(::withNetwork)
        snap.clockPercent?.let(clockHistory::add)
        memoryHistory.add(snap.memoryPercentUsed)
        thermalHistory.add(snap.thermalState.toDouble())
        // The bench samples thermals from the core: keep it current.
        runCatching { Native.setThermal(snap.thermalState, snap.batteryTempC ?: Double.NaN) }
        return snap
    }

    // --- CPU ------------------------------------------------------------------------------

    private data class Cpu(
        val total: Int,
        val performance: Int,
        val efficiency: Int,
        val clusters: List<Cluster>,
        val clockPercent: Double?,
    )

    private fun cpu(): Cpu {
        val total = Runtime.getRuntime().availableProcessors()
        val cores = (0 until total).map { i ->
            val dir = File("/sys/devices/system/cpu/cpu$i/cpufreq")
            Cpufreq.reading(
                Sys.readLong(File(dir, "scaling_cur_freq")),
                Sys.readLong(File(dir, "cpuinfo_max_freq")),
            )
        }
        // Clusters = cores sharing a maximum clock (big.LITTLE / DynamIQ tiers).
        val clusters = cores.filter { it.second != null }.groupBy { it.second!! }.toSortedMap()
            .map { (max, list) ->
                val cur = list.mapNotNull { it.first }.takeIf { it.isNotEmpty() }?.average()
                Cluster(list.size, cur?.let { (it / 1000).toInt() }, (max / 1000).toInt())
            }
        val pcts = cores.mapNotNull { (cur, max) -> if (cur != null && max != null && max > 0) cur * 100.0 / max else null }
        val top = clusters.lastOrNull()
        val performance = if (clusters.size > 1 && top != null) top.cores else total
        return Cpu(
            total = total,
            performance = performance,
            efficiency = if (clusters.size > 1) total - performance else 0,
            clusters = clusters,
            clockPercent = pcts.takeIf { it.isNotEmpty() }?.average()?.coerceIn(0.0, 100.0),
        )
    }

    private fun soc(): String = if (Build.VERSION.SDK_INT >= 31) {
        listOf(Build.SOC_MANUFACTURER, Build.SOC_MODEL)
            .filter { it.isNotBlank() && it != Build.UNKNOWN }
            .joinToString(" ")
            .ifEmpty { Build.HARDWARE }
    } else {
        Build.HARDWARE
    }

    private fun marketingName(): String {
        // The name the user sees in Settings › About ("Pixel 9 Pro"), else the model.
        val name = runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
        val model = Build.MODEL
        val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        return when {
            model.startsWith(maker, ignoreCase = true) -> model
            name != null && name.isNotBlank() && !name.equals(model, true) && name.contains(model.take(4), true) -> name
            else -> "$maker $model"
        }
    }

    // --- Memory and storage -----------------------------------------------------------------

    private fun memory(): ActivityManager.MemoryInfo = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }

    private fun appFootprint(): Long = runCatching {
        val info = Debug.MemoryInfo()
        Debug.getMemoryInfo(info)
        info.totalPss.toLong() * 1024
    }.getOrDefault(0)

    private fun withMeminfo(s: DeviceSnapshot): DeviceSnapshot {
        val m = Sys.meminfo() ?: return s
        val cached = listOfNotNull(m["Cached"], m["Buffers"], m["SReclaimable"]).sum().takeIf { it > 0 }
        return s.copy(memoryCached = cached, swapTotal = m["SwapTotal"]?.takeIf { it > 0 }, swapFree = m["SwapFree"])
    }

    private fun withStorage(s: DeviceSnapshot): DeviceSnapshot = runCatching {
        val st = StatFs(Environment.getDataDirectory().path)
        s.copy(storageTotal = st.totalBytes, storageFree = st.availableBytes)
    }.getOrDefault(s)

    // --- Battery ------------------------------------------------------------------------------

    private fun withBattery(s: DeviceSnapshot): DeviceSnapshot {
        val i: Intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return s
        if (!i.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true)) return s
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val status = when (i.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "Charging"
            BatteryManager.BATTERY_STATUS_FULL -> "Full"
            BatteryManager.BATTERY_STATUS_DISCHARGING -> "Unplugged"
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "Not charging"
            else -> "Unknown"
        }
        val plugged = when (i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)) {
            BatteryManager.BATTERY_PLUGGED_AC -> "AC"
            BatteryManager.BATTERY_PLUGGED_USB -> "USB"
            BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
            BatteryManager.BATTERY_PLUGGED_DOCK -> "Dock"
            else -> null
        }
        val health = when (i.getIntExtra(BatteryManager.EXTRA_HEALTH, 0)) {
            BatteryManager.BATTERY_HEALTH_GOOD -> "Good"
            BatteryManager.BATTERY_HEALTH_OVERHEAT -> "Overheating"
            BatteryManager.BATTERY_HEALTH_DEAD -> "Dead"
            BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE -> "Over voltage"
            BatteryManager.BATTERY_HEALTH_COLD -> "Cold"
            BatteryManager.BATTERY_HEALTH_UNSPECIFIED_FAILURE -> "Failure"
            else -> null
        }
        val temp = i.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE).takeIf { it != Int.MIN_VALUE }?.div(10.0)
        val voltage = i.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1).takeIf { it > 0 }
        // µA; some vendors report mA. Positive = charging on most devices.
        val currentRaw = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW).takeIf { it != Int.MIN_VALUE && it != 0 }
        val currentMa = currentRaw?.let { if (kotlin.math.abs(it) > 20_000) it / 1000 else it }
        val charge = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER).takeIf { it > 0 }?.div(1000)
        val cycles = if (Build.VERSION.SDK_INT >= 34) {
            i.getIntExtra(BatteryManager.EXTRA_CYCLE_COUNT, -1).takeIf { it >= 0 }
        } else {
            null
        }
        return s.copy(
            batteryLevel = if (level >= 0 && scale > 0) level.toDouble() / scale else null,
            batteryState = status,
            plugged = plugged,
            batteryHealth = health,
            batteryTempC = temp,
            batteryVoltageMv = voltage,
            batteryCurrentMa = currentMa,
            batteryChargeMah = charge,
            batteryCycles = cycles,
            batteryTechnology = i.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY)?.takeIf { it.isNotBlank() },
        )
    }

    // --- Network ------------------------------------------------------------------------------

    private fun withNetwork(s: DeviceSnapshot): DeviceSnapshot {
        val net = cm.activeNetwork ?: return s.copy(interfaceType = "Offline")
        val caps: NetworkCapabilities = cm.getNetworkCapabilities(net) ?: return s.copy(interfaceType = "Offline")
        val link: LinkProperties? = cm.getLinkProperties(net)
        val type = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Wired"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
            else -> "Other"
        }
        val vpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
            cm.allNetworksCompat().any { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }
        val ips = link?.linkAddresses.orEmpty().map { it.address }
            .sortedBy { if (it is Inet4Address) 0 else 1 }
            .mapNotNull { a -> a.hostAddress?.substringBefore('%')?.let { "${link?.interfaceName ?: ""} $it".trim() } }
        val gateway = link?.routes.orEmpty().firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress
        var wifi = s
        if (type == "Wi-Fi") {
            wifi = wifiInfo(s)
        }
        return wifi.copy(
            interfaceType = type,
            interfaceName = link?.interfaceName,
            metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            dataSaver = cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED,
            vpnActive = vpn,
            localIPs = ips,
            dns = link?.dnsServers.orEmpty().mapNotNull { it.hostAddress },
            gateway = gateway,
            privateDns = link?.privateDnsServerName ?: if (link?.isPrivateDnsActive == true) "Automatic" else null,
            downKbps = caps.linkDownstreamBandwidthKbps.takeIf { it > 0 },
            upKbps = caps.linkUpstreamBandwidthKbps.takeIf { it > 0 },
        )
    }

    @Suppress("DEPRECATION")
    private fun ConnectivityManager.allNetworksCompat() = allNetworks.toList()

    /** RSSI, link speed and band. (The network name needs location access; Blip doesn't ask.) */
    @Suppress("DEPRECATION")
    private fun wifiInfo(s: DeviceSnapshot): DeviceSnapshot = runCatching {
        val wm = context.applicationContext.getSystemService(WifiManager::class.java)
        val info = wm.connectionInfo ?: return s
        s.copy(
            wifiRssi = info.rssi.takeIf { it in -127..0 },
            wifiLinkMbps = info.linkSpeed.takeIf { it > 0 },
            wifiFrequencyMhz = info.frequency.takeIf { it > 0 },
        )
    }.getOrDefault(s)
}

/** One core's (current, maximum) clock in kHz, with unbelievable figures dropped. */
object Cpufreq {
    /** No phone core tops out below this; smaller maxima are an emulator's or kernel's stand-ins. */
    private const val LOWEST_BELIEVABLE_MAX_KHZ = 100_000L

    fun reading(cur: Long?, max: Long?): Pair<Long?, Long?> {
        if (max == null || max < LOWEST_BELIEVABLE_MAX_KHZ) return null to null
        return cur?.takeIf { it > 0 } to max
    }
}

/** World-readable sysfs/procfs helpers. */
object Sys {
    fun read(f: File): String? = runCatching { f.readText().trim() }.getOrNull()?.takeIf { it.isNotEmpty() }

    fun readLong(f: File): Long? = read(f)?.toLongOrNull()

    /** /proc/meminfo in bytes (still readable by apps on Android 10+). */
    fun meminfo(text: String? = read(File("/proc/meminfo"))): Map<String, Long>? {
        val t = text ?: return null
        return t.lines().mapNotNull { line ->
            val key = line.substringBefore(':', "").trim()
            val parts = line.substringAfter(':', "").trim().split(Regex("\\s+"))
            val n = parts.firstOrNull()?.toLongOrNull() ?: return@mapNotNull null
            key to if (parts.getOrNull(1) == "kB") n * 1024 else n
        }.toMap().takeIf { it.isNotEmpty() }
    }

    /** /proc/loadavg — readable on some devices, hidden by SELinux on others. */
    fun loadAverage(text: String? = read(File("/proc/loadavg"))): List<Double>? =
        text?.split(' ')?.take(3)?.mapNotNull { it.toDoubleOrNull() }?.takeIf { it.size == 3 }
}
