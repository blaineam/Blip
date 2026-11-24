// The tray app. No console window; `blip-cli.exe` is the command-line twin.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let has = |flag: &str| args.iter().any(|a| a == flag);
    // Launch-at-login passes --background: start in the tray without opening the popover.
    let background = has("--background");
    if has("--version") {
        println!("Blip {}", blip_app::VERSION);
        return;
    }

    // Windows per-user install (see install.rs): --uninstall, --install, the offer at first run.
    #[cfg(windows)]
    {
        use blip_app::install;
        if has("--uninstall") {
            install::uninstall(has("--quiet"));
            return;
        }
        if let Some(pid) = args
            .iter()
            .position(|a| a == "--wait")
            .and_then(|i| args.get(i + 1))
            .and_then(|p| p.parse().ok())
        {
            install::wait_for_pid(pid);
        }
        if has("--install") {
            install::close_running();
            match install::install() {
                Ok(exe) if !install::is_installed_copy() => install::launch(&exe, &["--show"]),
                Ok(_) => {}
                Err(e) => eprintln!("Blip couldn't be installed: {e}"),
            }
            return;
        }
        // Opened by hand from a download: offer to install (or update / open the installed copy).
        if !background
            && !has("--portable")
            && !has("--demo")
            && !install::is_installed_copy()
            && install::offer()
        {
            return;
        }
    }

    if let Err(e) = blip_app::app::run(!background && has("--show")) {
        eprintln!("Blip couldn't start: {e}");
        std::process::exit(1);
    }
}
