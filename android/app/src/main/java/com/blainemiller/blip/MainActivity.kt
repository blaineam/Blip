package com.blainemiller.blip

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Dashboard
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.blainemiller.blip.speed.PublicSpeedTestHost
import com.blainemiller.blip.stats.SnapshotExport
import com.blainemiller.blip.ui.BatteryDetail
import com.blainemiller.blip.ui.BenchScreen
import com.blainemiller.blip.ui.BlipTheme
import com.blainemiller.blip.ui.CpuDetail
import com.blainemiller.blip.ui.DeviceDetail
import com.blainemiller.blip.ui.GpuName
import com.blainemiller.blip.ui.MemoryDetail
import com.blainemiller.blip.ui.NetworkDetail
import com.blainemiller.blip.ui.NetworkToolsScreen
import com.blainemiller.blip.ui.OverviewScreen
import com.blainemiller.blip.ui.SettingsScreen
import com.blainemiller.blip.ui.SpeedScreen
import com.blainemiller.blip.ui.StorageDetail
import com.blainemiller.blip.ui.ThermalDetail
import com.blainemiller.blip.ui.t
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : ComponentActivity() {
    private val model: BlipModel by viewModels()
    private var pending by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        (application as BlipApplication).applyLanguage(resources.configuration.locales[0])
        enableEdgeToEdge()
        // Only a fresh launch runs a shortcut: a rotation or a return from Recents carries the
        // same intent and must not start another benchmark or speed test.
        val fromRecents = (intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        if (savedInstanceState == null && !fromRecents) pending = intent?.action
        setContent { BlipTheme { App(model, pending) { pending = null } } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        pending = intent.action
    }

    override fun onStart() {
        super.onStart()
        model.setVisible(true)
    }

    override fun onStop() {
        model.setVisible(false)
        super.onStop()
    }

    companion object {
        const val ACTION_BENCH = "com.blainemiller.blip.RUN_BENCHMARK"
        const val ACTION_SPEED = "com.blainemiller.blip.RUN_SPEED_TEST"
        const val ACTION_SNAPSHOT = "com.blainemiller.blip.SHARE_SNAPSHOT"
    }
}

private data class Tab(val route: String, val label: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun App(model: BlipModel, action: String?, consumed: () -> Unit) {
    val nav = rememberNavController()
    val context = LocalContext.current
    val device by model.device.collectAsState()
    val publicRun by model.publicRun.collectAsState()
    val tabs = listOf(
        Tab("overview", t("Overview"), Icons.Filled.Dashboard),
        Tab("bench", t("Bench"), Icons.Filled.Timer),
        Tab("speed", t("Speed"), Icons.Filled.Speed),
        Tab("network", t("Network"), Icons.Filled.Hub),
    )
    val entry by nav.currentBackStackEntryAsState()
    val route = entry?.destination?.route ?: "overview"
    val isTab = tabs.any { it.route == route }

    // Launcher shortcuts.
    LaunchedEffect(action) {
        when (action) {
            MainActivity.ACTION_BENCH -> {
                nav.go("bench")
                if (!model.bench.value.running) model.startBench(false)
            }
            MainActivity.ACTION_SPEED -> {
                nav.go("speed")
                if (!model.speed.value.running) model.startSpeed()
            }
            MainActivity.ACTION_SNAPSHOT -> shareSnapshot(context, model)
        }
        if (action != null) consumed()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(titleFor(route, tabs)) },
                navigationIcon = {
                    if (!isTab) {
                        IconButton(onClick = { nav.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, t("Back")) }
                    }
                },
                actions = {
                    if (route == "overview") {
                        IconButton(onClick = { shareSnapshot(context, model) }) { Icon(Icons.Filled.IosShare, t("Share snapshot")) }
                        IconButton(onClick = { nav.navigate("settings") }) { Icon(Icons.Filled.Settings, t("Settings")) }
                    }
                },
            )
        },
        bottomBar = {
            if (isTab) {
                NavigationBar {
                    for (tab in tabs) {
                        NavigationBarItem(
                            selected = route == tab.route,
                            onClick = { nav.go(tab.route) },
                            icon = { Icon(tab.icon, null) },
                            label = { Text(tab.label) },
                        )
                    }
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            NavHost(nav, startDestination = "overview") {
                composable("overview") {
                    val clock by model.clockHistory.collectAsState()
                    val mem by model.memoryHistory.collectAsState()
                    val th by model.thermalHistory.collectAsState()
                    OverviewScreen(device, clock, mem, th) { nav.navigate("detail/$it") }
                }
                composable("bench") {
                    val bench by model.bench.collectAsState()
                    BenchScreen(bench, model::startBench, model::cancelBench)
                }
                composable("speed") {
                    val speed by model.speed.collectAsState()
                    SpeedScreen(
                        speed, model.store.speedServerPublic, model.store.selfHostedUrl,
                        start = model::startSpeed, cancel = model::cancelSpeed, openSettings = { nav.navigate("settings") },
                    )
                }
                composable("network") {
                    val trace by model.trace.collectAsState()
                    val geo by model.geo.collectAsState()
                    NetworkToolsScreen(trace, geo, model.store.pingTarget, model::startTrace, model::stopTrace, model::downloadGeo)
                }
                composable("settings") {
                    val geo by model.geo.collectAsState()
                    SettingsScreen(model.store, geo, model::downloadGeo, model::removeGeo)
                }
                composable("detail/{id}") { back ->
                    when (back.arguments?.getString("id")) {
                        "cpu" -> CpuDetail(device, model.clockHistory.collectAsState().value)
                        "memory" -> MemoryDetail(device, model.memoryHistory.collectAsState().value)
                        "storage" -> {
                            val disk by model.disk.collectAsState()
                            StorageDetail(device, disk, diskTargets(context), model::startDisk, model::cancelDisk)
                        }
                        "network" -> {
                            val wan by model.wanIp.collectAsState()
                            val loading by model.wanLoading.collectAsState()
                            NetworkDetail(device, wan, loading, model::revealWanIp)
                        }
                        "battery" -> BatteryDetail(device)
                        "thermal" -> ThermalDetail(device, model.thermalHistory.collectAsState().value)
                        "device" -> {
                            val gpu by produceState<String?>(null) { value = withContext(Dispatchers.Default) { GpuName.get() } }
                            DeviceDetail(device, gpu)
                        }
                    }
                }
            }
            // The public speed test's page lives only while a public run is in flight.
            if (publicRun) PublicSpeedTestHost(onFinished = model::publicRunFinished)
        }
    }
}

private fun NavHostController.go(route: String) = navigate(route) {
    popUpTo("overview") { saveState = true }
    launchSingleTop = true
    restoreState = true
}

private fun titleFor(route: String, tabs: List<Tab>): String = when {
    route == "overview" -> "Blip"
    route == "settings" -> t("Settings")
    route.startsWith("detail") -> ""
    else -> tabs.firstOrNull { it.route == route }?.label ?: "Blip"
}

/** Internal storage, plus each removable volume's app folder (SD cards, USB drives). */
private fun diskTargets(context: android.content.Context): List<Pair<String, String>> {
    val out = mutableListOf(context.filesDir.absolutePath to t("Internal storage"))
    context.getExternalFilesDirs(null).drop(1).filterNotNull().forEachIndexed { i, dir ->
        out += dir.absolutePath to (if (i == 0) t("SD card") else "${t("External")} ${i + 1}")
    }
    return out
}

/** Writes the Markdown snapshot to the cache and opens the share sheet with the file. */
private fun shareSnapshot(context: android.content.Context, model: BlipModel) {
    val md = SnapshotExport.markdown(model.device.value, model.speed.value.history, model.bench.value.last)
    val dir = File(context.cacheDir, "snapshots").apply { mkdirs() }
    dir.listFiles()?.forEach { it.delete() }
    val name = "Blip-Snapshot-" + SimpleDateFormat("yyyy-MM-dd-HHmmss", Locale.US).format(Date()) + ".md"
    val file = File(dir, name).apply { writeText(md) }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val send = Intent(Intent.ACTION_SEND)
        .setType("text/markdown")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .putExtra(Intent.EXTRA_SUBJECT, name)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, t("Share snapshot")))
}
