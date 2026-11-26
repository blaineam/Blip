package com.blainemiller.blip

import android.content.Context
import org.json.JSONObject
import java.util.Locale

/**
 * Blip's strings: English keys, translated from the same catalogs the Mac and iPhone ship
 * (tools/gen_strings.py → assets/strings.json). A key with no translation shows as itself.
 */
object L {
    private var column = -1
    private var table: Map<String, List<String>> = emptyMap()

    fun load(context: Context, locale: Locale = Locale.getDefault()) {
        val text = context.assets.open("strings.json").bufferedReader().use { it.readText() }
        load(JSONObject(text), locale)
    }

    fun load(json: JSONObject, locale: Locale) {
        val langs = json.getJSONArray("langs").let { a -> List(a.length()) { a.getString(it) } }
        column = columnFor(langs, locale)
        val strings = json.getJSONObject("strings")
        val map = HashMap<String, List<String>>(strings.length() * 2)
        for (key in strings.keys()) {
            val row = strings.getJSONArray(key)
            map[key] = List(row.length()) { row.getString(it) }
        }
        table = map
    }

    /** The catalog column for a locale: exact "pt-BR" / "zh-Hans" first, then the language. */
    fun columnFor(langs: List<String>, locale: Locale): Int {
        val lang = locale.language
        val tag = locale.toLanguageTag()
        if (lang == "zh") return langs.indexOf("zh-Hans")
        if (lang == "pt") return langs.indexOf("pt-BR")
        return langs.indexOfFirst { it.equals(tag, true) }.takeIf { it >= 0 } ?: langs.indexOf(lang)
    }

    /** BCP-47 tag the core uses for its own messages. */
    fun languageTag(locale: Locale = Locale.getDefault()): String = locale.toLanguageTag()

    fun t(key: String): String {
        if (column < 0) return key
        return table[key]?.getOrNull(column)?.takeIf { it.isNotEmpty() } ?: key
    }

    /** Apple-style format: `%@`, `%lld`, `%d`, `%1$@`… filled in order (or by position). */
    fun tf(key: String, vararg args: Any?): String = format(t(key), *args)

    fun format(template: String, vararg args: Any?): String {
        val out = StringBuilder()
        var next = 0
        var i = 0
        val spec = Regex("""%(?:(\d+)\$)?(@|lld|ld|d|f|\.\d+f|%)""")
        while (i < template.length) {
            val m = spec.find(template, i)
            if (m == null || m.range.first != i) {
                val end = m?.range?.first ?: template.length
                out.append(template, i, end)
                i = end
                continue
            }
            val kind = m.groupValues[2]
            if (kind == "%") {
                out.append('%')
            } else {
                val index = m.groupValues[1].toIntOrNull()?.minus(1) ?: next++
                val value = args.getOrNull(index)
                out.append(
                    when {
                        kind.endsWith("f") && value is Number ->
                            String.format(Locale.getDefault(), "%" + kind, value.toDouble())
                        else -> value?.toString() ?: ""
                    },
                )
            }
            i = m.range.last + 1
        }
        return out.toString()
    }
}
