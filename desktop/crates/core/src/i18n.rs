//! UI strings in the Mac app's languages. English is the key (exactly as in the Mac string
//! catalog, so `%@`/`%lld` placeholders carry over); `tools/gen_strings.py` builds the table
//! from `Blip/Resources/Localizable.xcstrings` plus the desktop-only strings.

use std::sync::atomic::{AtomicUsize, Ordering};

use crate::strings::{LANGS, TABLE};

const NONE: usize = usize::MAX;
static LANG: AtomicUsize = AtomicUsize::new(NONE);

/// Picks the UI language from a BCP-47 tag ("de-DE", "pt-BR", "zh-Hans-CN", "zh-CN"…).
/// Unknown tags, and Traditional Chinese, fall back to English.
pub fn set_language(tag: &str) {
    LANG.store(column_for(tag).unwrap_or(NONE), Ordering::Relaxed);
}

/// The active language code ("en" when English).
pub fn language() -> &'static str {
    match LANG.load(Ordering::Relaxed) {
        NONE => "en",
        i => LANGS[i],
    }
}

pub fn column_for(tag: &str) -> Option<usize> {
    let lower = tag.to_ascii_lowercase().replace('_', "-");
    let primary = lower.split('-').next().unwrap_or("");
    let code = match primary {
        "de" => "de",
        "es" => "es",
        "fr" => "fr",
        "it" => "it",
        "ja" => "ja",
        "ko" => "ko",
        "pt" => "pt-BR",
        "zh" => {
            let traditional = lower.contains("hant")
                || lower.ends_with("-tw")
                || lower.ends_with("-hk")
                || lower.ends_with("-mo");
            if traditional {
                return None;
            }
            "zh-Hans"
        }
        _ => return None,
    };
    LANGS.iter().position(|l| *l == code)
}

fn lookup(key: &str, col: usize) -> Option<&'static str> {
    if col == NONE {
        return None;
    }
    TABLE.binary_search_by(|(k, _)| (*k).cmp(key)).ok().map(|i| TABLE[i].1[col]).filter(|s| !s.is_empty())
}

/// The UI string for `key` (its English text) in the user's language.
pub fn t(key: &str) -> String {
    lookup(key, LANG.load(Ordering::Relaxed)).map(str::to_owned).unwrap_or_else(|| key.to_owned())
}

/// `t` + placeholder substitution. Handles the Apple-catalog specifiers the keys use —
/// `%@`, `%lld`, `%d`, `%ld`, `%f`/`%.1f`, positional `%1$@` — and `%%`.
pub fn tf(key: &str, args: &[&dyn std::fmt::Display]) -> String {
    format_apple(&t(key), args)
}

pub fn format_apple(template: &str, args: &[&dyn std::fmt::Display]) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let chars: Vec<char> = template.chars().collect();
    let mut next = 0usize;
    let mut i = 0;
    while i < chars.len() {
        if chars[i] != '%' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        if i + 1 < chars.len() && chars[i + 1] == '%' {
            out.push('%');
            i += 2;
            continue;
        }
        // %[n$][flags/width/precision][l|ll|h]conv
        let mut j = i + 1;
        let mut index: Option<usize> = None;
        let start = j;
        while j < chars.len() && chars[j].is_ascii_digit() {
            j += 1;
        }
        if j < chars.len() && chars[j] == '$' && j > start {
            index = chars[start..j].iter().collect::<String>().parse::<usize>().ok().map(|n| n - 1);
            j += 1;
        } else {
            j = start;
        }
        let mut precision: Option<usize> = None;
        while j < chars.len() && (chars[j].is_ascii_digit() || chars[j] == '.' || chars[j] == '-') {
            if chars[j] == '.' {
                let p0 = j + 1;
                let mut p1 = p0;
                while p1 < chars.len() && chars[p1].is_ascii_digit() {
                    p1 += 1;
                }
                precision = chars[p0..p1].iter().collect::<String>().parse().ok();
                j = p1;
            } else {
                j += 1;
            }
        }
        while j < chars.len() && (chars[j] == 'l' || chars[j] == 'h' || chars[j] == 'q') {
            j += 1;
        }
        if j >= chars.len() {
            out.extend(&chars[i..]);
            break;
        }
        let conv = chars[j];
        if !matches!(conv, '@' | 'd' | 'i' | 'u' | 'f' | 's' | 'x') {
            out.extend(&chars[i..=j]);
            i = j + 1;
            continue;
        }
        let k = index.unwrap_or_else(|| {
            let k = next;
            next += 1;
            k
        });
        if let Some(arg) = args.get(k) {
            let s = arg.to_string();
            match (conv, precision) {
                ('f', Some(p)) => match s.parse::<f64>() {
                    Ok(v) => out.push_str(&format!("{v:.p$}")),
                    Err(_) => out.push_str(&s),
                },
                _ => out.push_str(&s),
            }
        }
        i = j + 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_apple_specifiers() {
        assert_eq!(format_apple("%@ is using %lld%% CPU", &[&"Chrome", &97]), "Chrome is using 97% CPU");
        assert_eq!(format_apple("%2$@ / %1$@", &[&"a", &"b"]), "b / a");
        assert_eq!(format_apple("%.1f GB", &[&4.56]), "4.6 GB");
        assert_eq!(format_apple("no args", &[]), "no args");
    }

    #[test]
    fn languages() {
        assert_eq!(column_for("de-DE").map(|c| LANGS[c]), Some("de"));
        assert_eq!(column_for("pt-BR").map(|c| LANGS[c]), Some("pt-BR"));
        assert_eq!(column_for("zh-Hans-CN").map(|c| LANGS[c]), Some("zh-Hans"));
        assert_eq!(column_for("zh-TW"), None);
        assert_eq!(column_for("en-US"), None);
    }

    #[test]
    fn table_is_sorted_for_binary_search() {
        assert!(TABLE.windows(2).all(|w| w[0].0 < w[1].0));
    }
}
