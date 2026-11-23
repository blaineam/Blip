// The tray app. No console window; `blip-cli.exe` is the command-line twin.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Launch-at-login passes --background: start in the tray without opening the popover.
    let background = args.iter().any(|a| a == "--background");
    if args.iter().any(|a| a == "--version") {
        println!("Blip {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if let Err(e) = blip_app::app::run(!background && args.iter().any(|a| a == "--show")) {
        eprintln!("Blip couldn't start: {e}");
        std::process::exit(1);
    }
}
