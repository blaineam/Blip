//! `blip-cli` — Blip's command line (the Windows counterpart of the Mac's Shortcuts actions).
fn main() {
    std::process::exit(blip_app::cli::run(std::env::args().skip(1).collect()));
}
