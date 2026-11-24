//! App icons for the process lists: the executable is matched to an installed `.desktop` entry
//! (by its Exec, StartupWMClass or file name), and that entry's icon is looked up as a PNG in the
//! hicolor theme, pixmaps, Flatpak and Snap exports.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

fn data_dirs() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Some(h) = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
    {
        v.push(h);
    }
    let sys = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    v.extend(sys.split(':').filter(|s| !s.is_empty()).map(PathBuf::from));
    for extra in [
        "/var/lib/flatpak/exports/share",
        "/var/lib/snapd/desktop",
        "/usr/share",
    ] {
        let p = PathBuf::from(extra);
        if !v.contains(&p) {
            v.push(p);
        }
    }
    v
}

/// executable basename / WM class / desktop id (lowercase) → Icon= value.
fn index() -> &'static HashMap<String, String> {
    static I: OnceLock<HashMap<String, String>> = OnceLock::new();
    I.get_or_init(|| {
        let mut map = HashMap::new();
        for d in data_dirs() {
            let Ok(rd) = std::fs::read_dir(d.join("applications")) else {
                continue;
            };
            for e in rd.flatten() {
                let p = e.path();
                if p.extension().is_none_or(|x| x != "desktop") {
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&p) else {
                    continue;
                };
                let (exec, icon, wm) = parse_desktop(&text);
                let Some(icon) = icon else { continue };
                let mut keys = Vec::new();
                if let Some(e) = exec.as_deref().and_then(exec_name) {
                    keys.push(e);
                }
                if let Some(w) = wm {
                    keys.push(w.to_ascii_lowercase());
                }
                if let Some(stem) = p.file_stem() {
                    let s = stem.to_string_lossy().to_ascii_lowercase();
                    keys.push(s.rsplit('.').next().unwrap_or(&s).to_string());
                    keys.push(s);
                }
                for k in keys {
                    map.entry(k).or_insert_with(|| icon.clone());
                }
            }
        }
        map
    })
}

/// (Exec, Icon, StartupWMClass) from the [Desktop Entry] group.
pub fn parse_desktop(text: &str) -> (Option<String>, Option<String>, Option<String>) {
    let mut in_entry = false;
    let (mut exec, mut icon, mut wm) = (None, None, None);
    for l in text.lines() {
        let l = l.trim();
        if l.starts_with('[') {
            in_entry = l == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some(v) = l.strip_prefix("Exec=") {
            exec.get_or_insert_with(|| v.to_string());
        } else if let Some(v) = l.strip_prefix("Icon=") {
            icon.get_or_insert_with(|| v.to_string());
        } else if let Some(v) = l.strip_prefix("StartupWMClass=") {
            wm.get_or_insert_with(|| v.to_string());
        }
    }
    (exec, icon, wm)
}

/// The program an Exec line runs, skipping `env VAR=…` and quoting.
pub fn exec_name(exec: &str) -> Option<String> {
    let mut words = exec.split_whitespace().map(|w| w.trim_matches('"'));
    let mut w = words.next()?;
    if w.ends_with("/env") || w == "env" {
        w = words.find(|x| !x.contains('='))?;
    }
    if w.ends_with("flatpak") {
        // flatpak run … org.app.Id
        return words
            .filter(|x| !x.starts_with('-'))
            .nth(1)
            .map(|s| s.to_ascii_lowercase());
    }
    Path::new(w)
        .file_name()
        .map(|f| f.to_string_lossy().to_ascii_lowercase())
}

fn find_png(icon: &str) -> Option<PathBuf> {
    let p = Path::new(icon);
    if p.is_absolute() {
        return (p.extension().is_some_and(|e| e == "png") && p.exists()).then(|| p.to_path_buf());
    }
    for d in data_dirs() {
        for size in [
            "32x32", "48x48", "24x24", "64x64", "22x22", "16x16", "128x128", "256x256",
        ] {
            let f = d
                .join("icons/hicolor")
                .join(size)
                .join("apps")
                .join(format!("{icon}.png"));
            if f.exists() {
                return Some(f);
            }
        }
    }
    data_dirs()
        .iter()
        .map(|d| d.join("pixmaps").join(format!("{icon}.png")))
        .find(|f| f.exists())
}

fn decode_png(path: &Path) -> Option<(u32, u32, Vec<u8>)> {
    let file = std::fs::File::open(path).ok()?;
    let mut dec = png::Decoder::new(std::io::BufReader::new(file));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let px = &buf[..info.buffer_size()];
    let rgba: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => px.to_vec(),
        png::ColorType::Rgb => px.chunks(3).flat_map(|c| [c[0], c[1], c[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => px.chunks(2).flat_map(|c| [c[0], c[0], c[0], c[1]]).collect(),
        png::ColorType::Grayscale => px.iter().flat_map(|g| [*g, *g, *g, 255]).collect(),
        png::ColorType::Indexed => return None,
    };
    let (w, h) = (info.width, info.height);
    // Keep list icons small: box-downsample big ones to ≤ 64 px.
    let mut f = 1;
    while w / f > 64 {
        f *= 2;
    }
    if f == 1 {
        return Some((w, h, rgba));
    }
    let (nw, nh) = (w / f, h / f);
    let mut out = vec![0u8; (nw * nh * 4) as usize];
    for y in 0..nh {
        for x in 0..nw {
            let mut acc = [0u32; 4];
            for dy in 0..f {
                for dx in 0..f {
                    let i = (((y * f + dy) * w + (x * f + dx)) * 4) as usize;
                    for k in 0..4 {
                        acc[k] += rgba[i + k] as u32;
                    }
                }
            }
            let o = ((y * nw + x) * 4) as usize;
            for k in 0..4 {
                out[o + k] = (acc[k] / (f * f)) as u8;
            }
        }
    }
    Some((nw, nh, out))
}

pub fn exe_icon(exe: &str) -> Option<(u32, u32, Vec<u8>)> {
    let name = Path::new(exe).file_name()?.to_string_lossy().to_ascii_lowercase();
    let idx = index();
    let icon = idx
        .get(&name)
        .or_else(|| idx.get(name.trim_end_matches("-bin")))
        .or_else(|| idx.get(name.split('-').next().unwrap_or(&name)))?;
    decode_png(&find_png(icon)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_parsing() {
        let t = "[Desktop Entry]\nName=Firefox\nExec=env MOZ_X=1 /usr/lib/firefox/firefox %u\nIcon=firefox\n[Desktop Action new]\nExec=other\n";
        let (exec, icon, _) = parse_desktop(t);
        assert_eq!(exec_name(&exec.unwrap()).as_deref(), Some("firefox"));
        assert_eq!(icon.as_deref(), Some("firefox"));
        assert_eq!(
            exec_name("/usr/bin/flatpak run --branch=stable org.gimp.GIMP").as_deref(),
            Some("org.gimp.gimp")
        );
    }
}
