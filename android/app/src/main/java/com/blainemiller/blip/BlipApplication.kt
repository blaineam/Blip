package com.blainemiller.blip

import android.app.Application
import android.content.res.Configuration
import com.blainemiller.blip.core.Native
import com.blainemiller.blip.widget.Widgets
import java.util.Locale

class BlipApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        applyLanguage(resources.configuration.locales[0])
    }

    /** The phone's language, or Blip's own on Android 13+, can change while the process lives. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (applyLanguage(newConfig.locales[0])) Widgets.refresh(this)
    }

    /**
     * Loads the app's and the native core's strings for [locale]. Does nothing, and returns false,
     * when they are already in it. The activity calls this too: it can be recreated for a new
     * language before the application hears about the change.
     */
    fun applyLanguage(locale: Locale): Boolean {
        if (locale == language) return false
        language = locale
        L.load(this, locale)
        val (model, os) = BlipModel.deviceLabel()
        // After the first call this only switches the core's language.
        Native.init(filesDir.absolutePath, L.languageTag(locale), model, os)
        return true
    }

    private var language: Locale? = null
}
