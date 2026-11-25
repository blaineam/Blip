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

    blip_core::log(&format!(
        "Blip {} starting ({} {}, args {args:?})",
        blip_app::VERSION,
        std::env::consts::OS,
        std::env::consts::ARCH
    ));
    // The release build aborts on panic and has no console: say what happened before dying.
    std::panic::set_hook(Box::new(|info| {
        let text = info.to_string();
        blip_core::log(&format!("crash: {text}"));
        fatal(&text);
    }));
    match blip_app::app::run(!background && has("--show")) {
        Ok(()) => blip_core::log("quit"),
        Err(e) => {
            blip_core::log(&format!("couldn't start: {e}"));
            fatal(&e.to_string());
            std::process::exit(1);
        }
    }
}

/// Tells the user why Blip is closing. `BLIP_NO_DIALOG` skips the box (CI, scripts).
fn fatal(reason: &str) {
    let message = format!(
        "Blip couldn't run:\n\n{reason}\n\nDetails are in {}",
        blip_core::paths::log_file().display()
    );
    eprintln!("{message}");
    #[cfg(windows)]
    if std::env::var_os("BLIP_NO_DIALOG").is_none() {
        blip_app::install::error_box(&message);
    }
}
