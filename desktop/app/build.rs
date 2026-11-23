// Embeds the icon, the manifest (asInvoker — Windows never prompts for admin — and per-monitor
// DPI awareness) and version info. Only when targeting Windows from a Windows host, since the
// resource compiler is Windows-only; cross-checks from macOS/Linux skip it.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=res/blip.ico");
    println!("cargo:rerun-if-changed=res/blip.manifest");
    println!("cargo:rerun-if-env-changed=BLIP_VERSION");
    #[cfg(windows)]
    embed();
}

#[cfg(windows)]
fn embed() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let version = std::env::var("BLIP_VERSION")
        .unwrap_or_else(|_| std::env::var("CARGO_PKG_VERSION").expect("package version"));
    let mut res = winresource::WindowsResource::new();
    res.set_icon_with_id("res/blip.ico", "1");
    res.set_manifest_file("res/blip.manifest");
    res.set("ProductName", "Blip");
    res.set("FileDescription", "Blip: system monitor");
    res.set("CompanyName", "Blaine Miller");
    res.set("LegalCopyright", "MIT License");
    res.set("ProductVersion", &version);
    res.set("FileVersion", &version);
    res.compile().expect("embedding Windows resources failed");
}
