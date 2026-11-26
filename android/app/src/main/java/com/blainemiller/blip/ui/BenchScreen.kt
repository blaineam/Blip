package com.blainemiller.blip.ui

import android.content.Intent
import android.opengl.EGL14
import android.opengl.GLES20
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blainemiller.blip.core.BenchResult
import com.blainemiller.blip.core.BenchState
import com.blainemiller.blip.stats.Fmt

@Composable
fun BenchScreen(state: BenchState, start: (quick: Boolean) -> Unit, cancel: () -> Unit) = DetailColumn {
    val context = LocalContext.current
    val view = LocalView.current
    DisposableEffect(state.running) {
        view.keepScreenOn = state.running
        onDispose { view.keepScreenOn = false }
    }
    Text(
        t("Measure what this device can actually do — CPU, memory and GPU throughput scored in Blip's fixed reference units, comparable with every other device running Blip."),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Spacer(Modifier.height(12.dp))
    if (state.running) {
        Text(state.phaseLabel, style = MaterialTheme.typography.titleMedium)
        LinearProgressIndicator(progress = { state.progress.toFloat() }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp))
        for (leg in state.legs) {
            KV(leg.name, if (leg.id == "sustained") Fmt.percent(leg.score) else Fmt.score(leg.score))
        }
        OutlinedButton(onClick = cancel) { Text(t("Cancel")) }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { start(false) }) { Text(t("Run Benchmark")) }
            OutlinedButton(onClick = { start(true) }) { Text(t("Quick")) }
        }
        Caption(t("The full run takes about 90 seconds, including 45 seconds of sustained load to measure throttling. Keep Blip open."))
    }
    state.last?.let { r ->
        SectionTitle(t("Last result"))
        ResultCard(r, state.best)
        OutlinedButton(onClick = {
            val text = tf("Blip Bench: %@ on %@", Fmt.score(r.composite), r.deviceModel) + "\nhttps://wemiller.com/apps/blip/"
            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
        }) { Text(t("Share")) }
    }
    if (state.history.size > 1) {
        SectionTitle(t("History"))
        for (r in state.history.reversed().take(10)) {
            KV(Fmt.date(r.date) + if (r.profile == "quick") " · " + t("Quick") else "", Fmt.score(r.composite))
        }
    }
}

@Composable
private fun ResultCard(r: BenchResult, best: Double?) {
    Column {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(Fmt.score(r.composite), fontSize = 40.sp, fontWeight = FontWeight.Bold, color = Tint.Purple)
            Spacer(Modifier.padding(4.dp))
            if (best != null && r.composite >= best) Text(t("Personal best"), color = Tint.Green, style = MaterialTheme.typography.labelLarge)
        }
        KV(t("CPU · single-core"), Fmt.score(r.singleCore.score))
        KV(t("CPU · all cores"), Fmt.score(r.multiCore.score))
        KV(t("Memory"), Fmt.score(r.memory.score))
        KV(t("GPU"), r.gpu?.let { Fmt.score(it.score) } ?: "—")
        r.throttlePercentLost?.let { KV(t("Sustained"), if (it == 0) t("No throttling") else tf("%@% slower under load", it)) }
        Caption("${r.deviceModel} · ${Fmt.date(r.date)}")
    }
}

/** The GL renderer string ("Adreno (TM) 750"), read once from a throwaway EGL pbuffer context. */
object GpuName {
    @Volatile private var cached: String? = null

    fun get(): String? {
        cached?.let { return it }
        val name = runCatching {
            val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val ver = IntArray(2)
            EGL14.eglInitialize(display, ver, 0, ver, 1)
            val attrs = intArrayOf(EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE)
            val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
            val n = IntArray(1)
            EGL14.eglChooseConfig(display, attrs, 0, configs, 0, 1, n, 0)
            val ctx = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            val surface = EGL14.eglCreatePbufferSurface(display, configs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
            EGL14.eglMakeCurrent(display, surface, surface, ctx)
            val r = GLES20.glGetString(GLES20.GL_RENDERER)
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, ctx)
            EGL14.eglTerminate(display)
            r
        }.getOrNull()?.takeIf { it.isNotBlank() }
        cached = name
        return name
    }
}
