package com.blainemiller.blip.stats

import com.blainemiller.blip.core.BenchResult
import com.blainemiller.blip.core.SpeedResult
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * One-file "everything Blip knows right now" export — the iPhone app's Markdown, in Android's
 * terms: pasteable into an issue, a chat or a wiki, and still diffable.
 */
object SnapshotExport {
    fun markdown(s: DeviceSnapshot, speeds: List<SpeedResult>, bench: BenchResult?): String {
        val stamp = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.MEDIUM).format(Date())
        val booted = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(s.bootMillis))
        val cores = if (s.coresEfficiency > 0) "${s.coresTotal} (${s.coresPerformance}P + ${s.coresEfficiency}E)" else "${s.coresTotal}"
        val battery = s.batteryLevel?.let { "${(it * 100).toInt()}%" } ?: "—"
        val sb = StringBuilder()
        sb.append("# Blip Snapshot — ${s.marketingName}\n_${stamp}_\n\n")
        table(sb, "Device", listOf(
            "Model" to "${s.marketingName} (`${s.manufacturer} ${s.model}`)",
            "OS" to "Android ${s.androidVersion} (API ${s.sdk}) · patch ${s.securityPatch}",
            "SoC" to s.soc.ifEmpty { "—" },
            "Booted" to booted,
            "Uptime" to "${Fmt.uptime(s.uptimeMs)} (awake ${Fmt.uptime(s.awakeMs)})",
            "Cores" to cores,
            "Thermal" to s.thermalLabel + (s.thermalHeadroom?.let { String.format(Locale.US, " · headroom %.2f", it) } ?: ""),
            "Battery" to "$battery · ${s.batteryState}" + (if (s.powerSave) " · Battery Saver" else ""),
        ))
        table(sb, "CPU", buildList {
            add("Clock vs max" to (s.clockPercent?.let(Fmt::percent) ?: "—"))
            s.clusters.forEach { c -> add("${c.cores} × ${Fmt.mhz(c.maxMhz)}" to (c.curMhz?.let(Fmt::mhz) ?: "—")) }
            s.load?.let { add("Load 1/5/15" to String.format(Locale.US, "%.2f / %.2f / %.2f", it[0], it[1], it[2])) }
        })
        table(sb, "Memory", buildList {
            add("Physical" to Fmt.memory(s.memoryTotal))
            add("Available" to Fmt.memory(s.memoryAvailable))
            s.memoryCached?.let { add("Cached" to Fmt.memory(it)) }
            s.swapTotal?.let { t -> add("Swap (zram)" to "${Fmt.memory(t - (s.swapFree ?: 0))} of ${Fmt.memory(t)}") }
            add("Blip's footprint" to Fmt.memory(s.appFootprint))
        })
        table(sb, "Storage", listOf(
            "Used" to Fmt.percent(s.storagePercentUsed),
            "Free" to "${Fmt.bytes(s.storageFree)} of ${Fmt.bytes(s.storageTotal)}",
        ))
        val flags = buildList {
            if (s.metered) add("metered")
            if (s.dataSaver) add("data saver")
        }.ifEmpty { listOf("unrestricted") }.joinToString(", ")
        table(sb, "Network", buildList {
            add("Interface" to (s.interfaceType + (s.interfaceName?.let { " ($it)" } ?: "")))
            add("Path" to flags)
            add("VPN" to if (s.vpnActive) "Active" else "Not detected")
            s.gateway?.let { add("Router" to it) }
            if (s.dns.isNotEmpty()) add("DNS" to s.dns.joinToString(", "))
            s.wifiRssi?.let { add("Wi-Fi signal" to "$it dBm") }
        })
        if (s.localIPs.isNotEmpty()) {
            sb.append("### Local addresses\n")
            s.localIPs.forEach { sb.append("- `$it`\n") }
            sb.append('\n')
        }
        if (bench != null) {
            sb.append("## Blip Bench\n- ${Fmt.score(bench.composite)} (${bench.profile}) — ${Fmt.date(bench.date)}\n\n")
        }
        if (speeds.isNotEmpty()) {
            sb.append("## Recent speed tests\n")
            speeds.takeLast(5).reversed().forEach { r ->
                val up = r.upMbps?.let { String.format(Locale.US, " / %.0f up", it) } ?: ""
                val source = if (r.server == "public" || r.server.isEmpty()) "OpenSpeedTest" else r.server
                sb.append("- ${Fmt.date(r.timestamp)}: ${String.format(Locale.US, "%.0f", r.downMbps)} Mbps down$up — $source\n")
            }
            sb.append('\n')
        }
        sb.append("---\n_Captured by Blip · [wemiller.com/apps/blip](https://wemiller.com/apps/blip/)_\n")
        return sb.toString()
    }

    private fun table(sb: StringBuilder, title: String, rows: List<Pair<String, String>>) {
        sb.append("## $title\n| | |\n|---|---|\n")
        rows.forEach { (k, v) -> sb.append("| $k | $v |\n") }
        sb.append('\n')
    }
}
