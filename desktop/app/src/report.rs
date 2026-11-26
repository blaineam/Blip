//! Where "Report an issue" goes. The Linux beta opens GitHub's bug form with the version and
//! system details filled in; the reporter sees them there before submitting anything.

pub const ISSUES: &str = "https://github.com/blaineam/blip/issues";

pub fn issue_url() -> String {
    if cfg!(target_os = "linux") {
        let env = |name: &str| std::env::var(name).unwrap_or_default();
        let os_release = std::fs::read_to_string("/etc/os-release").unwrap_or_default();
        let system = linux_system(
            &os_release,
            std::env::consts::ARCH,
            &env("XDG_CURRENT_DESKTOP"),
            &env("XDG_SESSION_TYPE"),
        );
        linux_form(crate::VERSION, &system)
    } else {
        ISSUES.to_string()
    }
}

/// "Ubuntu 24.04.1 LTS, x86_64, GNOME, wayland" — unknown parts are left out.
fn linux_system(os_release: &str, arch: &str, desktop: &str, session: &str) -> String {
    let distro = os_release
        .lines()
        .find_map(|l| l.strip_prefix("PRETTY_NAME="))
        .map(|v| v.trim().trim_matches('"'))
        .unwrap_or("");
    [distro, arch, desktop, session]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join(", ")
}

/// The query names are the field ids in .github/ISSUE_TEMPLATE/linux-beta.yml.
fn linux_form(version: &str, system: &str) -> String {
    format!(
        "{ISSUES}/new?template=linux-beta.yml&version={}&system={}",
        encode(version),
        encode(system)
    )
}

fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_line_skips_unknown_parts() {
        let os = "NAME=Ubuntu\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n";
        assert_eq!(
            linux_system(os, "x86_64", "ubuntu:GNOME", "wayland"),
            "Ubuntu 24.04.1 LTS, x86_64, ubuntu:GNOME, wayland"
        );
        assert_eq!(linux_system("", "aarch64", "", ""), "aarch64");
    }

    #[test]
    fn form_is_prefilled_and_matches_the_template() {
        let url = linux_form("2.1.0-beta.1", "Rocky Linux 8.10 (Green Obsidian), x86_64 & more");
        assert!(url.ends_with(
            "/issues/new?template=linux-beta.yml&version=2.1.0-beta.1\
             &system=Rocky%20Linux%208.10%20%28Green%20Obsidian%29%2C%20x86_64%20%26%20more"
        ));
        let template = include_str!("../../../.github/ISSUE_TEMPLATE/linux-beta.yml");
        for id in ["version", "system"] {
            assert!(template.contains(&format!("id: {id}\n")), "no field `{id}`");
        }
    }
}
