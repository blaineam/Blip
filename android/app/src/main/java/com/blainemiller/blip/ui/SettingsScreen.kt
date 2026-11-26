package com.blainemiller.blip.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.blainemiller.blip.BuildConfig
import com.blainemiller.blip.Store
import com.blainemiller.blip.core.GeoStatus

@Composable
fun SettingsScreen(store: Store, geo: GeoStatus, downloadGeo: () -> Unit, removeGeo: () -> Unit) = DetailColumn {
    val context = LocalContext.current
    var isPublic by remember { mutableStateOf(store.speedServerPublic) }
    var url by remember { mutableStateOf(store.selfHostedUrl) }
    var pingTarget by remember { mutableStateOf(store.pingTarget) }

    SectionTitle(t("Speed test server"))
    Row(verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected = isPublic, onClick = { isPublic = true; store.speedServerPublic = true })
        Text(t("OpenSpeedTest (public)"))
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected = !isPublic, onClick = { isPublic = false; store.speedServerPublic = false })
        Text(t("Self-hosted"))
    }
    if (!isPublic) {
        OutlinedTextField(
            value = url,
            onValueChange = { url = it; store.selfHostedUrl = it },
            label = { Text(t("Server address")) },
            placeholder = { Text("http://192.168.1.10:3000") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Caption(t("An OpenSpeedTest server on your network or VPS, e.g. the openspeedtest Docker image."))
    }

    SectionTitle(t("Network tools"))
    OutlinedTextField(
        value = pingTarget,
        onValueChange = { pingTarget = it; store.pingTarget = it },
        label = { Text(t("Default ping host")) },
        singleLine = true,
        modifier = Modifier.fillMaxWidth(),
    )
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            when (geo.state) {
                "ready" -> t("Hop locations: installed")
                "downloading" -> t("Downloading…")
                else -> t("Hop locations: not installed")
            },
            Modifier.weight(1f),
        )
        if (geo.state == "ready") {
            TextButton(onClick = removeGeo) { Text(t("Remove")) }
        } else if (geo.state != "downloading") {
            TextButton(onClick = downloadGeo) { Text(t("Download")) }
        }
    }

    SectionTitle(t("About"))
    Text("Blip ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.bodyMedium)
    Caption(t("Blip is free and open source. If it's useful to you, you can chip in."))
    for ((label, link) in listOf(
        "GitHub Sponsors" to "https://github.com/sponsors/blaineam",
        "Ko-fi" to "https://ko-fi.com/blaineam",
        t("Source code") to "https://github.com/blaineam/blip",
        t("Report an issue") to "https://github.com/blaineam/blip/issues",
    )) {
        TextButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link))) }, modifier = Modifier.padding(0.dp)) {
            Text(label)
        }
    }
    Caption(t("Blip runs as you — no special permissions, no tracking, nothing leaves the device unless you run a network test."))
}
