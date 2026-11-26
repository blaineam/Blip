package com.blainemiller.blip

import android.app.Application
import android.os.Build
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.blainemiller.blip.core.BenchState
import com.blainemiller.blip.core.DiskState
import com.blainemiller.blip.core.GeoStatus
import com.blainemiller.blip.core.Native
import com.blainemiller.blip.core.SpeedState
import com.blainemiller.blip.core.TraceState
import com.blainemiller.blip.stats.DeviceSnapshot
import com.blainemiller.blip.stats.DeviceStats
import com.blainemiller.blip.widget.Widgets
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The app's single source of truth: device stats every 2 s, and the native core's test state —
 * polled every 250 ms while something runs, every 2 s otherwise.
 */
class BlipModel(app: Application) : AndroidViewModel(app) {
    val store = Store(app)
    private val stats = DeviceStats(app)

    private val _device = MutableStateFlow(DeviceSnapshot())
    val device: StateFlow<DeviceSnapshot> = _device
    private val _clock = MutableStateFlow<List<Double>>(emptyList())
    val clockHistory: StateFlow<List<Double>> = _clock
    private val _memory = MutableStateFlow<List<Double>>(emptyList())
    val memoryHistory: StateFlow<List<Double>> = _memory
    private val _thermal = MutableStateFlow<List<Double>>(emptyList())
    val thermalHistory: StateFlow<List<Double>> = _thermal

    private val _bench = MutableStateFlow(BenchState())
    val bench: StateFlow<BenchState> = _bench
    private val _speed = MutableStateFlow(SpeedState())
    val speed: StateFlow<SpeedState> = _speed
    private val _disk = MutableStateFlow(DiskState())
    val disk: StateFlow<DiskState> = _disk
    private val _trace = MutableStateFlow(TraceState())
    val trace: StateFlow<TraceState> = _trace
    private val _geo = MutableStateFlow(GeoStatus("absent"))
    val geo: StateFlow<GeoStatus> = _geo

    private val _wanIp = MutableStateFlow<String?>(null)
    val wanIp: StateFlow<String?> = _wanIp
    private val _wanLoading = MutableStateFlow(false)
    val wanLoading: StateFlow<Boolean> = _wanLoading

    private val visible = MutableStateFlow(false)

    /** Cuts the idle poll short, so a test shows its progress as soon as it starts. */
    private val wake = Channel<Unit>(Channel.CONFLATED)

    /** A test in flight keeps sampling (and the bench's thermal feed) going in the background. */
    private val busy: Boolean
        get() = _bench.value.running || _speed.value.running || _disk.value.running ||
            _trace.value.running || _geo.value.state == "downloading"

    private suspend fun awaitWork() {
        if (!busy) visible.first { it }
    }

    fun setVisible(shown: Boolean) {
        visible.value = shown
        if (!shown) {
            // Leave the storage widget with the latest figures.
            writeDeviceFact(_device.value)
            Widgets.refresh(getApplication())
        }
    }

    private var factWrittenAt = 0L

    private fun writeDeviceFact(s: DeviceSnapshot) {
        if (s.storageTotal == 0L) return
        store.writeDevice(s.storageTotal, s.storageFree, s.thermalState, s.batteryLevel)
        factWrittenAt = SystemClock.elapsedRealtime()
    }

    /** A public speed run is waiting for the WebView (see speed/PublicSpeedTest.kt). */
    private val _publicRun = MutableStateFlow(false)
    val publicRun: StateFlow<Boolean> = _publicRun

    init {
        viewModelScope.launch {
            while (isActive) {
                awaitWork()
                val s = withContext(Dispatchers.Default) { stats.sample() }
                _device.value = s
                _clock.value = stats.clockHistory.toList()
                _memory.value = stats.memoryHistory.toList()
                _thermal.value = stats.thermalHistory.toList()
                if (factWrittenAt == 0L || SystemClock.elapsedRealtime() - factWrittenAt > 30_000) writeDeviceFact(s)
                delay(2000)
            }
        }
        viewModelScope.launch {
            var lastBench: Long? = null
            var lastSpeed: Long? = null
            while (isActive) {
                awaitWork()
                withContext(Dispatchers.Default) {
                    _bench.value = BenchState.parse(Native.benchState())
                    _speed.value = SpeedState.parse(Native.speedState())
                    _disk.value = DiskState.parse(Native.diskState())
                    _trace.value = TraceState.parse(Native.traceState())
                    _geo.value = GeoStatus.parse(Native.geoStatus())
                }
                // New results feed the widgets.
                _bench.value.last?.let { r ->
                    if (lastBench != null && r.date != lastBench) {
                        store.writeBench(r.composite, _bench.value.best, r.date)
                        Widgets.refresh(getApplication())
                    }
                    lastBench = r.date
                }
                _speed.value.last?.let { r ->
                    if (lastSpeed != null && r.timestamp != lastSpeed) {
                        store.writeSpeed(r.downMbps, r.upMbps, _device.value.interfaceType, r.timestamp)
                        Widgets.refresh(getApplication())
                    }
                    lastSpeed = r.timestamp
                }
                withTimeoutOrNull(if (busy) 250L else 2000L) { wake.receive() }
            }
        }
    }

    fun refresh() {
        viewModelScope.launch(Dispatchers.Default) { _device.value = stats.sample() }
    }

    fun startBench(quick: Boolean) {
        Native.benchStart(quick)
        wake.trySend(Unit)
    }
    fun cancelBench() = Native.benchCancel()

    /** Returns an error message for a bad self-hosted address. */
    fun startSpeed(): String? {
        if (store.speedServerPublic) {
            viewModelScope.launch(Dispatchers.IO) {
                // Measures latency first (blocking), then the WebView takes over.
                if (Native.speedBeginExternal()) _publicRun.value = true
                wake.trySend(Unit)
            }
            return null
        }
        return Native.speedStartSelfHosted(store.selfHostedUrl).also { wake.trySend(Unit) }
    }

    fun publicRunFinished() {
        _publicRun.value = false
    }

    fun cancelSpeed() {
        Native.speedCancel()
        _publicRun.value = false
    }

    fun startDisk(dir: String, sizeMb: Int, label: String) {
        Native.diskStart(dir, sizeMb, label)
        wake.trySend(Unit)
    }
    fun cancelDisk() = Native.diskCancel()

    fun startTrace(host: String): String? = Native.traceStart(host).also { wake.trySend(Unit) }
    fun stopTrace() = Native.traceStop()

    fun downloadGeo() {
        Native.geoDownload()
        wake.trySend(Unit)
    }

    fun removeGeo() {
        Native.geoRemove()
        wake.trySend(Unit)
    }

    fun revealWanIp() {
        if (_wanLoading.value) return
        _wanLoading.value = true
        viewModelScope.launch(Dispatchers.IO) {
            _wanIp.value = Native.wanIp()
            _wanLoading.value = false
        }
    }

    companion object {
        /** "Pixel 9 Pro", "Android 16" — what bench results are labelled with. */
        fun deviceLabel(): Pair<String, String> {
            val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
            val model = if (Build.MODEL.startsWith(maker, true)) Build.MODEL else "$maker ${Build.MODEL}"
            return model to "Android ${Build.VERSION.RELEASE}"
        }
    }
}
