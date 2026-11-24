//! OS dialogs and small shell integrations.

/// Folder picker for the disk test location.
pub fn pick_folder() -> Option<String> {
    #[cfg(any(windows, target_os = "linux"))]
    {
        rfd::FileDialog::new()
            .set_title(blip_core::t(
                "Pick a writable folder on the drive you want to benchmark.",
            ))
            .pick_folder()
            .map(|p| p.display().to_string())
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        None
    }
}

/// "Share a snapshot": save the Markdown export where the user chooses, then reveal it.
pub fn save_snapshot(markdown: &str) -> Option<String> {
    let name = format!(
        "Blip Snapshot {}.md",
        chrono::Local::now().format("%Y-%m-%d %H%M")
    );
    #[cfg(any(windows, target_os = "linux"))]
    let path = rfd::FileDialog::new()
        .set_file_name(&name)
        .add_filter("Markdown", &["md"])
        .save_file();
    #[cfg(not(any(windows, target_os = "linux")))]
    let path = std::env::var("HOME")
        .ok()
        .map(|h| std::path::PathBuf::from(h).join("Desktop").join(&name));
    let path = path?;
    std::fs::write(&path, markdown).ok()?;
    Some(path.display().to_string())
}
