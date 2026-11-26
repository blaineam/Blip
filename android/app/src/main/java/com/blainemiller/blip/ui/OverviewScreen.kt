package com.blainemiller.blip.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryChargingFull
import androidx.compose.material.icons.filled.BatteryFull
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material.icons.filled.DataSaverOn
import androidx.compose.material.icons.filled.DeveloperBoard
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.NetworkCell
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Power
import androidx.compose.material.icons.filled.SdStorage
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.blainemiller.blip.stats.DeviceSnapshot
import com.blainemiller.blip.stats.Fmt
import com.blainemiller.blip.stats.Suggestions

@Composable
fun OverviewScreen(
    s: DeviceSnapshot,
    clock: List<Double>,
    memory: List<Double>,
    thermal: List<Double>,
    open: (String) -> Unit,
) {
    val tips = Suggestions.evaluate(s)
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 164.dp),
        contentPadding = PaddingValues(16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (tips.isNotEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) { SuggestionsBox(tips) }
        }
        item {
            StatCard(Icons.Filled.DeveloperBoard, Tint.Blue, t("CPU"), onClick = { open("cpu") }) {
                BigValue(s.clockPercent?.let(Fmt::percent) ?: "${s.coresTotal}")
                Caption(if (s.clockPercent != null) t("Clock vs max") else t("Cores"))
                Sparkline(clock, Tint.Blue, domain = 0.0..100.0)
            }
        }
        item {
            StatCard(Icons.Filled.Memory, Tint.Blue, t("Memory"), onClick = { open("memory") }) {
                BigValue(Fmt.memory(s.memoryTotal), size = 22)
                Caption(tf("%@ available to apps", Fmt.memory(s.memoryAvailable)))
                Sparkline(memory, Tint.Blue, domain = 0.0..100.0)
            }
        }
        item {
            StatCard(Icons.Filled.Storage, Tint.Orange, t("Storage"), onClick = { open("storage") }) {
                BigValue(Fmt.percent(s.storagePercentUsed))
                UsageBar(s.storagePercentUsed / 100, if (s.storagePercentUsed > 90) Tint.Red else Tint.Orange)
                Caption(tf("%@ free of %@", Fmt.bytes(s.storageFree), Fmt.bytes(s.storageTotal)))
            }
        }
        item {
            StatCard(networkIcon(s), Tint.Teal, t("Network"), onClick = { open("network") }) {
                BigValue(t(s.interfaceType), size = 22)
                Caption(pathNote(s))
            }
        }
        item {
            val charging = s.batteryState == "Charging"
            StatCard(if (charging) Icons.Filled.BatteryChargingFull else Icons.Filled.BatteryFull, Tint.Green, t("Battery"), onClick = { open("battery") }) {
                BigValue(s.batteryLevel?.let { "${(it * 100).toInt()}%" } ?: "—")
                Caption(t(s.batteryState) + if (s.powerSave) " · " + t("Battery Saver") else "")
            }
        }
        item {
            StatCard(Icons.Filled.Thermostat, Tint.thermal(s.thermalState), t("Thermal"), onClick = { open("thermal") }) {
                BigValue(t(s.thermalLabel), color = Tint.thermal(s.thermalState), size = 22)
                Caption(t("System thermal state"))
                if (thermal.size > 2) Sparkline(thermal, Tint.thermal(s.thermalState), domain = 0.0..3.0)
            }
        }
        item(span = { GridItemSpan(maxLineSpan) }) {
            StatCard(Icons.Filled.PhoneAndroid, Tint.Purple, t("Device"), onClick = { open("device") }) {
                BigValue(s.marketingName, size = 18)
                Caption(tf("Up %@", Fmt.uptime(s.uptimeMs)) + " · Android ${s.androidVersion}")
            }
        }
    }
}

@Composable
private fun SuggestionsBox(items: List<Suggestions.Item>) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceContainer, RoundedCornerShape(14.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (item in items) {
            Row(verticalAlignment = Alignment.Top) {
                val (icon, tint) = when (item.kind) {
                    Suggestions.Kind.Storage -> Icons.Filled.SdStorage to Tint.Red
                    Suggestions.Kind.Thermal -> Icons.Filled.Thermostat to Tint.Orange
                    Suggestions.Kind.Power -> Icons.Filled.Power to Tint.Yellow
                    Suggestions.Kind.Data -> Icons.Filled.DataSaverOn to Tint.Teal
                    Suggestions.Kind.Memory -> Icons.Filled.Memory to Tint.Blue
                }
                Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(item.text, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

fun networkIcon(s: DeviceSnapshot) = when (s.interfaceType) {
    "Wi-Fi" -> Icons.Filled.Wifi
    "Cellular" -> Icons.Filled.NetworkCell
    "Wired" -> Icons.Filled.Cable
    "Offline" -> Icons.Filled.WifiOff
    else -> Icons.Filled.Wifi
}

fun pathNote(s: DeviceSnapshot): String {
    val notes = buildList {
        if (s.metered) add(t("metered"))
        if (s.dataSaver) add(t("Data Saver"))
        if (s.vpnActive) add("VPN")
    }
    return if (notes.isEmpty()) t("Current route") else notes.joinToString(" · ")
}
