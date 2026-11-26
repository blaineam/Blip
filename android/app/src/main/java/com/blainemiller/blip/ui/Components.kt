package com.blainemiller.blip.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.blainemiller.blip.L

/** Blip's category tints — the same hues as the Mac, iPhone and desktop apps. */
object Tint {
    val Blue = Color(0xFF0A84FF)
    val Green = Color(0xFF30D158)
    val Orange = Color(0xFFFF9F0A)
    val Red = Color(0xFFFF453A)
    val Yellow = Color(0xFFFFD60A)
    val Teal = Color(0xFF40C8E0)
    val Purple = Color(0xFFBF5AF2)
    val Pink = Color(0xFFFF375F)

    fun thermal(level: Int) = when (level) {
        0 -> Green
        1 -> Yellow
        2 -> Orange
        else -> Red
    }
}

@Composable
fun BlipTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 && dark -> dynamicDarkColorScheme(context)
        Build.VERSION.SDK_INT >= 31 -> dynamicLightColorScheme(context)
        dark -> darkColorScheme(primary = Tint.Blue)
        else -> lightColorScheme(primary = Tint.Blue)
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/** Shorthand for a translated string. */
fun t(key: String) = L.t(key)
fun tf(key: String, vararg args: Any?) = L.tf(key, *args)

@Composable
fun StatCard(
    icon: ImageVector,
    tint: Color,
    title: String,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Card(
        modifier = modifier.fillMaxWidth().let { if (onClick != null) it.clickable(onClick = onClick) else it },
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            content()
        }
    }
}

@Composable
fun BigValue(text: String, color: Color = Color.Unspecified, size: Int = 28) {
    Text(
        text,
        fontSize = size.sp,
        fontWeight = FontWeight.Bold,
        color = color,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
fun Caption(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** Session sparkline. `domain` fixes the scale (0–100 for percentages); otherwise it autoscales. */
@Composable
fun Sparkline(values: List<Double>, tint: Color, height: Int = 24, domain: ClosedFloatingPointRange<Double>? = null) {
    if (values.size < 2) {
        Spacer(Modifier.height(height.dp))
        return
    }
    val lo = domain?.start ?: values.min()
    val hi = (domain?.endInclusive ?: values.max()).let { if (it - lo < 1e-6) lo + 1 else it }
    Canvas(Modifier.fillMaxWidth().height(height.dp).semantics { contentDescription = "chart" }) {
        val step = size.width / (values.size - 1)
        val path = Path()
        values.forEachIndexed { i, v ->
            val y = size.height - ((v - lo) / (hi - lo)).toFloat().coerceIn(0f, 1f) * size.height
            if (i == 0) path.moveTo(0f, y) else path.lineTo(i * step, y)
        }
        drawPath(path, tint, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
    }
}

/** Two curves on one scale (download / upload). */
@Composable
fun DualCurve(a: List<Double>, aTint: Color, b: List<Double>, bTint: Color, height: Int = 80) {
    val all = a + b
    if (all.size < 2) {
        Spacer(Modifier.height(height.dp))
        return
    }
    val hi = (all.maxOrNull() ?: 1.0).coerceAtLeast(1.0)
    Canvas(Modifier.fillMaxWidth().height(height.dp)) {
        for ((values, tint) in listOf(a to aTint, b to bTint)) {
            if (values.size < 2) continue
            val step = size.width / (values.size - 1)
            val path = Path()
            values.forEachIndexed { i, v ->
                val y = size.height - (v / hi).toFloat().coerceIn(0f, 1f) * size.height
                if (i == 0) path.moveTo(0f, y) else path.lineTo(i * step, y)
            }
            drawPath(path, tint, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round))
        }
        drawLine(Color.Gray.copy(alpha = 0.3f), Offset(0f, size.height), Offset(size.width, size.height))
    }
}

@Composable
fun UsageBar(fraction: Double, tint: Color) {
    LinearProgressIndicator(
        progress = { fraction.toFloat().coerceIn(0f, 1f) },
        modifier = Modifier.fillMaxWidth().height(6.dp),
        color = tint,
        trackColor = tint.copy(alpha = 0.18f),
        strokeCap = StrokeCap.Round,
        drawStopIndicator = {},
    )
}

@Composable
fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 16.dp, bottom = 4.dp),
    )
}

/** A label/value row; `copy` = tap copies the value (reference values like addresses). */
@Composable
fun KV(label: String, value: String, copy: Boolean = false, valueColor: Color = Color.Unspecified) {
    val context = LocalContext.current
    Row(
        Modifier
            .fillMaxWidth()
            .let { if (copy) it.clickable { copyToClipboard(context, label, value) } else it }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontFamily = if (value.any(Char::isDigit)) FontFamily.Monospace else FontFamily.Default,
            color = valueColor,
            maxLines = 2,
        )
    }
}

fun copyToClipboard(context: Context, label: String, value: String) {
    val cm = context.getSystemService(ClipboardManager::class.java)
    cm.setPrimaryClip(ClipData.newPlainText(label, value))
    if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, L.t("Copied"), Toast.LENGTH_SHORT).show()
}
