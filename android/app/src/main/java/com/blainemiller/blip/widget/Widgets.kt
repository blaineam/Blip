package com.blainemiller.blip.widget

import android.content.Context
import android.text.format.DateUtils
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.blainemiller.blip.L
import com.blainemiller.blip.MainActivity
import com.blainemiller.blip.Store
import com.blainemiller.blip.stats.Fmt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Home-screen widgets: bench score, storage, last speed test — each fact stamped with its age. */
object Widgets {
    fun refresh(context: Context) {
        val app = context.applicationContext
        CoroutineScope(Dispatchers.Default).launch {
            runCatching {
                val mgr = GlanceAppWidgetManager(app)
                if (mgr.getGlanceIds(BenchWidget::class.java).isNotEmpty()) BenchWidget().updateAll(app)
                if (mgr.getGlanceIds(StorageWidget::class.java).isNotEmpty()) StorageWidget().updateAll(app)
                if (mgr.getGlanceIds(SpeedWidget::class.java).isNotEmpty()) SpeedWidget().updateAll(app)
            }
        }
    }

    fun age(at: Long): String =
        DateUtils.getRelativeTimeSpanString(at, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
}

@Composable
private fun Tile(title: String, value: String, detail: String, tint: Color) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(GlanceTheme.colors.widgetBackground)
            .cornerRadius(16.dp)
            .padding(12.dp)
            .clickable(actionStartActivity<MainActivity>()),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = TextStyle(color = ColorProvider(tint), fontSize = 12.sp, fontWeight = FontWeight.Medium))
        Text(value, style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 26.sp, fontWeight = FontWeight.Bold))
        Text(detail, style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 11.sp), maxLines = 2)
    }
}

class BenchWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val fact = Store(context).bench()
        provideContent {
            GlanceTheme {
                if (fact == null) {
                    Tile("Blip Bench", "—", L.t("Run a benchmark in Blip"), Color(0xFFBF5AF2))
                } else {
                    val best = fact.best?.let { " · " + L.tf("best %@", Fmt.score(it)) } ?: ""
                    Tile("Blip Bench", Fmt.score(fact.score), Widgets.age(fact.at) + best, Color(0xFFBF5AF2))
                }
            }
        }
    }
}

class StorageWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val fact = Store(context).device()
        provideContent {
            GlanceTheme {
                if (fact == null || fact.storageTotal == 0L) {
                    Tile(L.t("Storage"), "—", L.t("Open Blip once to measure"), Color(0xFFFF9F0A))
                } else {
                    val pct = (fact.storageTotal - fact.storageFree) * 100.0 / fact.storageTotal
                    Tile(
                        L.t("Storage"), Fmt.percent(pct),
                        L.tf("%@ free", Fmt.bytes(fact.storageFree)) + " · " + Widgets.age(fact.at),
                        if (pct > 90) Color(0xFFFF453A) else Color(0xFFFF9F0A),
                    )
                }
            }
        }
    }
}

class SpeedWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val fact = Store(context).speed()
        provideContent {
            GlanceTheme {
                if (fact == null) {
                    Tile(L.t("Speed"), "—", L.t("Run a speed test in Blip"), Color(0xFF30D158))
                } else {
                    val up = fact.up?.let { " · ↑ " + Fmt.mbps(it) } ?: ""
                    Tile(L.t("Speed"), "↓ " + Fmt.mbps(fact.down), L.t(fact.iface) + up + " · " + Widgets.age(fact.at), Color(0xFF30D158))
                }
            }
        }
    }
}

class BenchWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BenchWidget()
}

class StorageWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = StorageWidget()
}

class SpeedWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = SpeedWidget()
}
