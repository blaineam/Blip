package com.blainemiller.blip.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.blainemiller.blip.core.GeoStatus
import com.blainemiller.blip.core.Native
import com.blainemiller.blip.core.TraceState
import com.blainemiller.blip.stats.Fmt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

@Composable
fun NetworkToolsScreen(
    trace: TraceState,
    geo: GeoStatus,
    defaultHost: String,
    startTrace: (String) -> String?,
    stopTrace: () -> Unit,
    downloadGeo: () -> Unit,
) = DetailColumn {
    var mode by remember { mutableIntStateOf(0) }
    var host by remember { mutableStateOf(defaultHost) }
    var error by remember { mutableStateOf<String?>(null) }
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        listOf(t("Ping"), t("Traceroute")).forEachIndexed { i, label ->
            SegmentedButton(selected = mode == i, onClick = { mode = i }, shape = SegmentedButtonDefaults.itemShape(i, 2)) { Text(label) }
        }
    }
    OutlinedTextField(
        value = host,
        onValueChange = { host = it.trim() },
        label = { Text(t("Host or IP address")) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
    )
    if (!Native.icmpAvailable()) {
        Caption(t("This device blocks unprivileged ICMP, so ping and traceroute can't run here."))
    }
    if (mode == 0) {
        PingPanel(host)
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (trace.running) {
                OutlinedButton(onClick = stopTrace) { Text(t("Stop")) }
            } else {
                Button(onClick = { error = startTrace(host) }) { Text(t("Trace")) }
            }
        }
        (error ?: trace.error)?.let { Text(it, color = Tint.Red, style = MaterialTheme.typography.bodySmall) }
        if (trace.hops.isNotEmpty()) {
            Caption(tf("%@ · %@ passes", trace.host, trace.passes))
            HopHeader()
            for (h in trace.hops) {
                Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Text("${h.hop}", Modifier.width(24.dp), fontFamily = FontFamily.Monospace)
                    Column(Modifier.weight(1f)) {
                        Text(h.host.ifEmpty { "*" }, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                        h.geo?.place?.let { Caption(it) }
                    }
                    Text(String.format(Locale.getDefault(), "%.0f%%", h.loss), Modifier.width(44.dp), style = MaterialTheme.typography.bodySmall, color = if (h.loss > 0) Tint.Orange else MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(Fmt.ms(h.avg), Modifier.width(72.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                }
                HorizontalDivider()
            }
        }
        SectionTitle(t("Hop locations"))
        when (geo.state) {
            "ready" -> Caption(t("Offline map data is installed (DB-IP Lite)."))
            "downloading" -> Caption(t("Downloading…"))
            "failed" -> Caption(geo.error ?: "")
            else -> {
                Caption(t("A free offline IP-location database (DB-IP Lite) that annotates traceroute hops with city and country. Around 100 MB; downloaded once, updated monthly if you leave it installed. Lookups never leave the device."))
                TextButton(onClick = downloadGeo) { Text(t("Download")) }
            }
        }
    }
}

@Composable
private fun HopHeader() {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Text("#", Modifier.width(24.dp), style = MaterialTheme.typography.labelSmall)
        Text(t("Host"), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall)
        Text(t("Loss"), Modifier.width(44.dp), style = MaterialTheme.typography.labelSmall)
        Text(t("Avg"), Modifier.width(72.dp), style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
private fun PingPanel(host: String) {
    val scope = rememberCoroutineScope()
    val results = remember { mutableStateListOf<Double?>() }
    var job by remember { mutableStateOf<Job?>(null) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (job?.isActive == true) {
            OutlinedButton(onClick = { job?.cancel() }) { Text(t("Stop")) }
        } else {
            Button(onClick = {
                results.clear()
                job = scope.launch {
                    repeat(20) {
                        if (!isActive) return@launch
                        val ms = withContext(Dispatchers.IO) { Native.ping(host) }
                        results.add(ms.takeIf { it >= 0 })
                        delay(1000)
                    }
                }
            }) { Text(t("Ping")) }
        }
    }
    if (results.isNotEmpty()) {
        val ok = results.filterNotNull()
        KV(t("Sent"), "${results.size}")
        KV(t("Loss"), String.format(Locale.getDefault(), "%.0f%%", (results.size - ok.size) * 100.0 / results.size))
        if (ok.isNotEmpty()) {
            KV(t("Average"), Fmt.ms(ok.average()))
            KV(t("Best"), Fmt.ms(ok.min()))
            KV(t("Worst"), Fmt.ms(ok.max()))
        }
        Sparkline(results.map { it ?: 0.0 }, Tint.Teal, height = 50)
        for ((i, r) in results.withIndex().reversed().take(8)) {
            KV("#${i + 1}", r?.let(Fmt::ms) ?: t("Timeout"), valueColor = if (r == null) Tint.Orange else androidx.compose.ui.graphics.Color.Unspecified)
        }
    }
}
