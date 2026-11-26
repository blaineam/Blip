package com.blainemiller.blip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.blainemiller.blip.core.DiskState
import com.blainemiller.blip.stats.DeviceSnapshot
import com.blainemiller.blip.stats.Fmt
import java.util.Locale

@Composable
fun DetailColumn(content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) { content() }
}

@Composable
fun CpuDetail(s: DeviceSnapshot, clock: List<Double>) = DetailColumn {
    SectionTitle(t("Clock vs max"))
    BigValue(s.clockPercent?.let(Fmt::percent) ?: "—")
    Sparkline(clock, Tint.Blue, height = 60, domain = 0.0..100.0)
    Caption(t("Android hides other apps' CPU time, so Blip shows how hard the cores are being clocked against their maximum — what the system is actually asking of the chip."))
    SectionTitle(t("Cores"))
    KV(t("Cores"), if (s.coresEfficiency > 0) "${s.coresTotal} (${s.coresPerformance}P + ${s.coresEfficiency}E)" else "${s.coresTotal}")
    for (c in s.clusters.reversed()) {
        KV(tf("%@ × up to %@", c.cores, Fmt.mhz(c.maxMhz)), c.curMhz?.let(Fmt::mhz) ?: "—")
    }
    s.load?.let { KV(t("Load 1/5/15"), String.format(Locale.US, "%.2f / %.2f / %.2f", it[0], it[1], it[2])) }
    SectionTitle(t("Chip"))
    KV("SoC", s.soc.ifEmpty { "—" }, copy = true)
    KV("ABI", s.abi)
}

@Composable
fun MemoryDetail(s: DeviceSnapshot, history: List<Double>) = DetailColumn {
    SectionTitle(t("Memory"))
    BigValue(Fmt.percent(s.memoryPercentUsed))
    UsageBar(s.memoryPercentUsed / 100, Tint.Blue)
    Sparkline(history, Tint.Blue, height = 60, domain = 0.0..100.0)
    KV(t("Physical"), Fmt.memory(s.memoryTotal))
    KV(t("Available"), Fmt.memory(s.memoryAvailable))
    KV(t("In use"), Fmt.memory(s.memoryUsed))
    s.memoryCached?.let { KV(t("Cached"), Fmt.memory(it)) }
    s.swapTotal?.let { total -> KV(t("Swap (zram)"), "${Fmt.memory(total - (s.swapFree ?: 0))} / ${Fmt.memory(total)}") }
    KV(t("Low-memory threshold"), Fmt.memory(s.memoryThreshold))
    KV(t("Blip's footprint"), Fmt.memory(s.appFootprint))
    if (s.lowMemory) Caption(t("The system reports low memory: apps in the background are being closed."))
}

@Composable
fun StorageDetail(
    s: DeviceSnapshot,
    disk: DiskState,
    targets: List<Pair<String, String>>,
    start: (dir: String, sizeMb: Int, label: String) -> Unit,
    cancel: () -> Unit,
) = DetailColumn {
    SectionTitle(t("Storage"))
    BigValue(Fmt.percent(s.storagePercentUsed))
    UsageBar(s.storagePercentUsed / 100, if (s.storagePercentUsed > 90) Tint.Red else Tint.Orange)
    KV(t("Used"), Fmt.bytes(s.storageUsed))
    KV(t("Free"), Fmt.bytes(s.storageFree))
    KV(t("Capacity"), Fmt.bytes(s.storageTotal))

    SectionTitle(t("Disk speed test"))
    Caption(t("Writes and reads a test file with the cache bypassed, then deletes it."))
    var size by remember { mutableIntStateOf(512) }
    var target by remember { mutableIntStateOf(0) }
    if (targets.size > 1) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            targets.forEachIndexed { i, (_, label) ->
                FilterChip(selected = target == i, onClick = { target = i }, label = { Text(label) })
            }
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (mb in listOf(256, 512, 1024)) {
            FilterChip(selected = size == mb, onClick = { size = mb }, label = { Text(if (mb >= 1024) "1 GB" else "$mb MB") })
        }
    }
    Spacer(Modifier.height(8.dp))
    if (disk.running) {
        Text(
            when (disk.phase) {
                "write" -> t("Writing…")
                "read" -> t("Reading…")
                "random" -> t("Random reads…")
                else -> t("Preparing…")
            },
        )
        LinearProgressIndicator(progress = { disk.progress.toFloat() }, modifier = Modifier.fillMaxWidth())
        TextButton(onClick = cancel) { Text(t("Cancel")) }
    } else {
        val (dir, label) = targets.getOrElse(target) { targets.first() }
        Button(onClick = { start(dir, size, label) }) { Text(t("Run Test")) }
    }
    disk.error?.let { Text(it, color = Tint.Red, style = MaterialTheme.typography.bodySmall) }
    disk.last?.let { r ->
        KV(t("Write"), String.format(Locale.getDefault(), "%.0f MB/s", r.writeMbps))
        KV(t("Read"), String.format(Locale.getDefault(), "%.0f MB/s", r.readMbps))
        r.iops?.let { KV(t("Random 4K read"), String.format(Locale.getDefault(), "%,.0f IOPS", it)) }
        Caption("${r.target} · ${r.sizeMb} MB · ${Fmt.date(r.timestamp)}")
    }
}

@Composable
fun NetworkDetail(s: DeviceSnapshot, wanIp: String?, wanLoading: Boolean, reveal: () -> Unit) = DetailColumn {
    SectionTitle(t("Connection"))
    KV(t("Interface"), t(s.interfaceType) + (s.interfaceName?.let { " ($it)" } ?: ""))
    KV(t("Path"), pathNote(s))
    KV("VPN", if (s.vpnActive) t("Active") else t("Not detected"))
    s.downKbps?.let { KV(t("Estimated bandwidth"), "↓ ${Fmt.mbps(it / 1000.0)}" + (s.upKbps?.let { u -> " · ↑ ${Fmt.mbps(u / 1000.0)}" } ?: "")) }
    if (s.interfaceType == "Wi-Fi") {
        SectionTitle("Wi-Fi")
        s.wifiRssi?.let { KV(t("Signal"), "$it dBm") }
        s.wifiLinkMbps?.let { KV(t("Link speed"), "$it Mbps") }
        s.wifiFrequencyMhz?.let { KV(t("Band"), if (it >= 5925) "6 GHz" else if (it >= 4900) "5 GHz" else "2.4 GHz") }
    }
    SectionTitle(t("Addresses"))
    for (ip in s.localIPs) KV(t("Local"), ip.substringAfter(' '), copy = true)
    s.gateway?.let { KV(t("Router"), it, copy = true) }
    if (s.dns.isNotEmpty()) KV("DNS", s.dns.joinToString("\n"), copy = true)
    s.privateDns?.let { KV(t("Private DNS"), it) }
    Row {
        if (wanIp != null) {
            KV(t("Public IP"), wanIp, copy = true)
        } else {
            OutlinedButton(onClick = reveal, enabled = !wanLoading) {
                Text(if (wanLoading) t("Looking up…") else t("Show public IP"))
            }
        }
    }
}

@Composable
fun BatteryDetail(s: DeviceSnapshot) = DetailColumn {
    SectionTitle(t("Battery"))
    BigValue(s.batteryLevel?.let { "${(it * 100).toInt()}%" } ?: "—")
    s.batteryLevel?.let { UsageBar(it, Tint.Green) }
    KV(t("State"), t(s.batteryState))
    s.plugged?.let { KV(t("Power source"), t(it)) }
    s.batteryHealth?.let { KV(t("Health"), t(it)) }
    s.batteryCycles?.let { KV(t("Cycle Count"), "$it") }
    s.batteryTempC?.let { KV(t("Temperature"), String.format(Locale.getDefault(), "%.1f °C", it)) }
    s.batteryVoltageMv?.let { KV(t("Voltage"), String.format(Locale.getDefault(), "%.2f V", it / 1000.0)) }
    s.batteryCurrentMa?.let { KV(t("Current"), "$it mA") }
    s.batteryChargeMah?.let { KV(t("Charge"), "$it mAh") }
    s.batteryTechnology?.let { KV(t("Chemistry"), it) }
    KV(t("Battery Saver"), if (s.powerSave) t("On") else t("Off"))
}

@Composable
fun ThermalDetail(s: DeviceSnapshot, history: List<Double>) = DetailColumn {
    SectionTitle(t("Thermal"))
    BigValue(t(s.thermalLabel), color = Tint.thermal(s.thermalState))
    Sparkline(history, Tint.thermal(s.thermalState), height = 60, domain = 0.0..3.0)
    KV(t("Thermal status"), thermalStatusName(s.thermalStatusRaw))
    s.thermalHeadroom?.let {
        KV(t("Headroom"), String.format(Locale.getDefault(), "%.0f%%", (1 - it).coerceIn(0.0, 1.0) * 100))
        Caption(t("How far the device is from thermal throttling over the next 10 seconds, as Android forecasts it."))
    }
    s.batteryTempC?.let { KV(t("Battery temperature"), String.format(Locale.getDefault(), "%.1f °C", it)) }
}

private fun thermalStatusName(raw: Int) = when (raw) {
    0 -> t("None")
    1 -> t("Light")
    2 -> t("Moderate")
    3 -> t("Severe")
    4 -> t("Critical")
    5 -> t("Emergency")
    else -> t("Shutdown")
}

@Composable
fun DeviceDetail(s: DeviceSnapshot, gpu: String?) = DetailColumn {
    SectionTitle(t("Device"))
    KV(t("Model"), s.marketingName, copy = true)
    KV(t("Identifier"), "${s.manufacturer} ${s.model}", copy = true)
    KV(t("Android"), "${s.androidVersion} (API ${s.sdk})")
    KV(t("Security patch"), s.securityPatch)
    KV("SoC", s.soc.ifEmpty { "—" })
    gpu?.let { KV("GPU", it, copy = true) }
    SectionTitle(t("Uptime"))
    KV(t("Since boot"), Fmt.uptime(s.uptimeMs))
    KV(t("Awake"), Fmt.uptime(s.awakeMs))
    KV(t("Booted"), Fmt.date(s.bootMillis / 1000))
}
