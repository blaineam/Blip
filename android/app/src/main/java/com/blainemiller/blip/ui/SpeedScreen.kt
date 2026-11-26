package com.blainemiller.blip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.blainemiller.blip.core.SpeedState
import com.blainemiller.blip.stats.Fmt

@Composable
fun SpeedScreen(
    state: SpeedState,
    isPublic: Boolean,
    server: String,
    start: () -> String?,
    cancel: () -> Unit,
    openSettings: () -> Unit,
) = DetailColumn {
    var error by remember { mutableStateOf<String?>(null) }
    Text(
        if (isPublic) {
            t("Runs OpenSpeedTest's public test in the background and graphs the result here. Public infra — manual runs only.")
        } else {
            server.ifBlank { t("Set your server's address in Settings.") }
        },
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(12.dp))
    if (state.running) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(Modifier.height(24.dp))
            Text(
                when (state.phase) {
                    "latency" -> t("Measuring latency…")
                    "upload" -> t("Upload")
                    else -> t("Download")
                },
                style = MaterialTheme.typography.titleMedium,
            )
        }
        BigValue(Fmt.mbps(state.liveMbps), color = if (state.phase == "upload") Tint.Blue else Tint.Green, size = 36)
        DualCurve(state.down, Tint.Green, state.up, Tint.Blue)
        OutlinedButton(onClick = cancel) { Text(t("Cancel")) }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = { error = start() },
                enabled = isPublic || server.isNotBlank(),
            ) { Text(t("Run Test")) }
            OutlinedButton(onClick = openSettings) { Text(t("Server")) }
        }
    }
    (error ?: state.error)?.let { Text(it, color = Tint.Red, style = MaterialTheme.typography.bodySmall) }
    state.last?.let { r ->
        SectionTitle(t("Last result"))
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            androidx.compose.foundation.layout.Column {
                Caption(t("Down"))
                BigValue(Fmt.mbps(r.downMbps), color = Tint.Green, size = 24)
            }
            r.upMbps?.let {
                androidx.compose.foundation.layout.Column {
                    Caption(t("Up"))
                    BigValue(Fmt.mbps(it), color = Tint.Blue, size = 24)
                }
            }
        }
        KV(t("Latency"), Fmt.ms(r.pingMs))
        r.loadedPingMs?.let { KV(t("Latency under load"), Fmt.ms(it)) }
        Caption((if (r.server == "public" || r.server.isEmpty()) "OpenSpeedTest" else r.server) + " · " + Fmt.date(r.timestamp))
        if (!state.running && state.down.size > 1) DualCurve(state.down, Tint.Green, state.up, Tint.Blue, height = 60)
    }
    if (state.history.size > 1) {
        SectionTitle(t("History"))
        for (r in state.history.reversed().take(10)) {
            KV(Fmt.date(r.timestamp), "↓ ${Fmt.mbps(r.downMbps)}" + (r.upMbps?.let { " ↑ ${Fmt.mbps(it)}" } ?: ""))
        }
    }
}
