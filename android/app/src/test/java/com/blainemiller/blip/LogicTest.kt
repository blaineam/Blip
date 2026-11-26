package com.blainemiller.blip

import com.blainemiller.blip.core.BenchState
import com.blainemiller.blip.stats.Cpufreq
import com.blainemiller.blip.core.SpeedState
import com.blainemiller.blip.core.TraceState
import com.blainemiller.blip.stats.DeviceSnapshot
import com.blainemiller.blip.stats.Fmt
import com.blainemiller.blip.stats.Suggestions
import com.blainemiller.blip.stats.Sys
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Locale

class LogicTest {
    private fun strings(): JSONObject {
        // Unit tests run from app/: the generated catalog the APK ships.
        return JSONObject(File("src/main/assets/strings.json").readText())
    }

    @Test
    fun catalogTranslatesAndFormats() {
        L.load(strings(), Locale.GERMANY)
        assertEquals("Arbeitsspeicher", L.t("Memory"))
        assertEquals("No such key", L.t("No such key"))
        assertTrue(L.tf("%@ × up to %@", 4, "2.00 GHz").startsWith("4 × bis"))
        L.load(strings(), Locale.forLanguageTag("pt-PT"))
        assertEquals("Rede", L.t("Network"))
        L.load(strings(), Locale.forLanguageTag("zh-TW"))
        assertEquals("网络", L.t("Network"))
        L.load(strings(), Locale.US)
        assertEquals("Network", L.t("Network"))
    }

    @Test
    fun appleFormatSpecifiers() {
        assertEquals("a 1 b x", L.format("a %lld b %@", 1, "x"))
        assertEquals("x then 1", L.format("%2\$@ then %1\$@", 1, "x"))
        assertEquals("50%", L.format("%@%", 50))
    }

    @Test
    fun procfsParsing() {
        val m = Sys.meminfo("MemTotal:  8000 kB\nCached:   100 kB\nHugePages_Total: 0\n")!!
        assertEquals(8000L * 1024, m["MemTotal"])
        assertEquals(0L, m["HugePages_Total"])
        assertEquals(listOf(1.5, 0.25, 0.1), Sys.loadAverage("1.50 0.25 0.10 2/300 123"))
        assertNull(Sys.loadAverage(null))
    }

    @Test
    fun placeholderClocksAreIgnored() {
        assertEquals(1_800_000L to 2_400_000L, Cpufreq.reading(1_800_000, 2_400_000))
        assertEquals(null to 2_400_000L, Cpufreq.reading(null, 2_400_000))
        assertEquals(null to null, Cpufreq.reading(1, 1))
        assertEquals(null to null, Cpufreq.reading(1_800_000, null))
    }

    @Test
    fun thermalScale() {
        assertEquals(0, DeviceSnapshot.thermalLevel(0))
        assertEquals(1, DeviceSnapshot.thermalLevel(2))
        assertEquals(2, DeviceSnapshot.thermalLevel(3))
        assertEquals(3, DeviceSnapshot.thermalLevel(6))
    }

    @Test
    fun formatting() {
        assertEquals("128 GB", Fmt.bytes(128_000_000_000))
        assertEquals("12.0 GB", Fmt.memory(12L shl 30))
        assertEquals("2d 3h", Fmt.uptime((2 * 86400 + 3 * 3600 + 59) * 1000L))
        assertEquals("2.40 GHz", Fmt.mhz(2400))
    }

    @Test
    fun coreJsonParses() {
        val bench = BenchState.parse(
            """{"running":false,"phase":"done","phaseLabel":"Done","progress":1,"legs":[],
               "last":{"date":1700000000,"profile":"full","composite":1234.5,
                 "single_core":{"name":"Single","score":1000,"results":[]},
                 "multi_core":{"name":"Multi","score":3000,"results":[]},
                 "memory":{"name":"Memory","score":900,"results":[]},
                 "gpu":null,"neural":null,"throttle_factor":0.82,"thermal_samples":[],
                 "device_model":"Pixel 9","os_version":"Android 16"},
               "history":[],"best":1234.5}""",
        )
        assertEquals(1234.5, bench.last!!.composite, 0.0)
        assertEquals(18, bench.last!!.throttlePercentLost)
        assertNull(bench.last!!.gpu)
        val speed = SpeedState.parse("""{"phase":"failed","error":"nope","running":false,"liveMbps":0,"down":[1,2],"up":[],"last":null,"history":[]}""")
        assertEquals("nope", speed.error)
        assertEquals(listOf(1.0, 2.0), speed.down)
        val trace = TraceState.parse(
            """{"host":"1.1.1.1","running":true,"passes":2,"error":null,"hops":[
              {"hop":1,"host":"10.0.0.1","sent":2,"recv":2,"loss":0,"last":1.2,"avg":1.1,"best":1,"worst":1.3,"geo":null},
              {"hop":2,"host":"","sent":2,"recv":0,"loss":100,"last":null,"avg":null,"best":null,"worst":null,
               "geo":{"lat":1,"lon":2,"city":"Denver","country":"United States"}}]}""",
        )
        assertEquals(2, trace.hops.size)
        assertNull(trace.hops[1].avg)
        assertEquals("Denver, United States", trace.hops[1].geo!!.place)
    }

    @Test
    fun suggestionsOnlyWhenSignalsFire() {
        L.load(strings(), Locale.US)
        assertTrue(Suggestions.evaluate(DeviceSnapshot(storageTotal = 100, storageFree = 50, memoryAvailable = 4L shl 30)).isEmpty())
        val ids = Suggestions.evaluate(
            DeviceSnapshot(storageTotal = 100, storageFree = 5, thermalState = 2, dataSaver = true, memoryAvailable = 4L shl 30),
        ).map { it.id }
        assertEquals(listOf("storage", "thermal", "datasaver"), ids)
    }
}
