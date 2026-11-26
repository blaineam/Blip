package com.blainemiller.blip.core

/**
 * The shared Rust core (desktop/crates/android): the same BenchKit, speed and disk tests,
 * ping/traceroute and GeoIP as Blip on the Mac, iPhone, Windows and Linux. Structured state comes
 * back as JSON (see [CoreState]). Every call is cheap except where noted; runs happen on the
 * core's own threads and the UI polls the *State calls.
 */
object Native {
    init {
        System.loadLibrary("blip_android")
    }

    external fun init(dataDir: String, language: String, model: String, os: String)
    external fun setThermal(state: Int, temperatureC: Double)

    external fun benchStart(quick: Boolean)
    external fun benchCancel()
    external fun benchState(): String

    /** Returns an error message, or null once the run has started. */
    external fun speedStartSelfHosted(base: String): String?
    external fun speedBeginExternal(): Boolean
    external fun speedExternalProgress(upload: Boolean, mbps: Double)
    external fun speedExternalComplete(down: Double, up: Double)
    external fun speedExternalFail(message: String)
    external fun speedExternalCancelled(): Boolean
    external fun speedCancel()
    external fun speedState(): String

    external fun diskStart(dir: String, sizeMb: Int, label: String)
    external fun diskCancel()
    external fun diskState(): String

    /** Blocking (up to ~1 s): call off the main thread. Negative = no answer. */
    external fun ping(host: String): Double
    external fun traceStart(host: String): String?
    external fun traceStop()
    external fun traceState(): String
    external fun icmpAvailable(): Boolean

    external fun geoStatus(): String
    external fun geoDownload()
    external fun geoRemove()

    /** The public address (network call, up to ~8 s): off the main thread, on request only. */
    external fun wanIp(): String?
    external fun translate(key: String): String
}
