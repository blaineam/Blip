//! `blip-cli`: the Windows counterpart of the Mac's Shortcuts actions — same metric ids, same
//! settings keys, same tools. Output is plain text by default, `--json` for scripts.

use std::time::Duration;

use blip_core::bench::{BenchEngine, Profile};
use blip_core::settings::Settings;
use blip_core::{fmt, metrics};

const HELP: &str = "blip-cli — Blip's command line

USAGE
  blip-cli metric <id> [--avg|--min|--max] [--seconds N] [--raw]
  blip-cli metrics                       list metric ids
  blip-cli snapshot [--json|--md]        everything Blip knows right now
  blip-cli ping <host> [--count N]
  blip-cli trace <host> [--passes N]     traceroute / MTR summary
  blip-cli speedtest [--server URL]      self-hosted OpenSpeedTest server (default: Settings)
  blip-cli disktest [--size 128|512|1024] [--path DIR]
  blip-cli bench [--quick] [--json]      Blip Bench (records into the app's history)
  blip-cli awake <minutes> [--display]   keep the PC awake while this runs (0 = until Ctrl+C)
  blip-cli get <key> | set <key> <value> | settings
  blip-cli open                          open the Blip popover
  blip-cli --version

Everything runs as you: no administrator rights needed.";

fn flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn opt<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

fn positional(args: &[String], n: usize) -> Option<&str> {
    let mut seen = 0;
    let mut skip = false;
    for a in args {
        if skip {
            skip = false;
            continue;
        }
        if a.starts_with("--") {
            skip = matches!(
                a.as_str(),
                "--seconds" | "--count" | "--passes" | "--server" | "--size" | "--path"
            );
            continue;
        }
        if seen == n {
            return Some(a);
        }
        seen += 1;
    }
    None
}

pub fn run(args: Vec<String>) -> i32 {
    let s = Settings::load();
    crate::state::apply_language(&s.language);
    let cmd = positional(&args, 0).unwrap_or("");
    let rest: Vec<String> = {
        let mut r = args.clone();
        if let Some(i) = r.iter().position(|a| a == cmd) {
            r.remove(i);
        }
        r
    };
    match cmd {
        "" if flag(&args, "--version") => {
            println!("Blip {}", crate::VERSION);
            0
        }
        "" | "help" => {
            println!("{HELP}");
            if cmd.is_empty() && !flag(&args, "--help") && !flag(&args, "-h") {
                1
            } else {
                0
            }
        }
        "metrics" => {
            for m in metrics::CATALOG {
                println!(
                    "{:<20} {}{}",
                    m.id,
                    m.title,
                    if m.has_history { "  (avg/min/max)" } else { "" }
                );
            }
            0
        }
        "metric" => metric(&rest),
        "snapshot" => {
            let snap = blip_platform::snapshot_once(Duration::from_millis(1000));
            if flag(&rest, "--json") {
                println!("{}", serde_json::to_string_pretty(&snap).unwrap_or_default());
            } else {
                print!("{}", blip_core::export::markdown(&snap, &[], None));
            }
            0
        }
        "ping" => {
            let Some(host) = positional(&rest, 0) else {
                return usage();
            };
            let n: usize = opt(&rest, "--count").and_then(|c| c.parse().ok()).unwrap_or(4);
            let mut ok = 0;
            for _ in 0..n {
                match blip_platform::ping(host) {
                    Some(ms) => {
                        ok += 1;
                        println!("{host}: {}", fmt::ms(Some(ms)));
                    }
                    None => println!("{host}: timed out"),
                }
                std::thread::sleep(Duration::from_millis(500));
            }
            if ok > 0 {
                0
            } else {
                2
            }
        }
        "trace" => trace(&rest),
        "speedtest" => speedtest(&rest, &s),
        "disktest" => disktest(&rest, &s),
        "bench" => bench(&rest),
        "awake" => awake(&rest),
        "get" => {
            let Some(key) = positional(&rest, 0) else {
                return usage();
            };
            match s.get(key) {
                Some(v) => {
                    println!("{v}");
                    0
                }
                None => {
                    eprintln!("unknown setting: {key}");
                    2
                }
            }
        }
        "set" => {
            let (Some(key), Some(value)) = (positional(&rest, 0), positional(&rest, 1)) else {
                return usage();
            };
            let mut s = s;
            match s.set(key, value) {
                Ok(()) => {
                    s.save();
                    if key == "launchAtLogin" {
                        let _ = blip_platform::set_launch_at_login(s.launch_at_login);
                    }
                    println!("{key} = {}", s.get(key).unwrap_or_default());
                    println!("(A running Blip picks this up when you next open Settings or restart it.)");
                    0
                }
                Err(e) => {
                    eprintln!("{e}");
                    2
                }
            }
        }
        "settings" => {
            for (k, help) in Settings::CLI_KEYS {
                println!("{:<28} {:<24} {help}", k, s.get(k).unwrap_or_default());
            }
            0
        }
        "open" => {
            let exe = std::env::current_exe().ok().and_then(|p| {
                p.parent()
                    .map(|d| d.join(if cfg!(windows) { "Blip.exe" } else { "Blip" }))
            });
            match exe.and_then(|e| std::process::Command::new(e).arg("--show").spawn().ok()) {
                Some(_) => 0,
                None => {
                    eprintln!("Couldn't start Blip.exe next to blip-cli.");
                    2
                }
            }
        }
        other => {
            eprintln!("unknown command: {other}\n");
            usage()
        }
    }
}

fn usage() -> i32 {
    eprintln!("{HELP}");
    1
}

fn metric(args: &[String]) -> i32 {
    let Some(id) = positional(args, 0) else {
        return usage();
    };
    let Some(m) = metrics::find(id) else {
        eprintln!("unknown metric: {id} (see `blip-cli metrics`)");
        return 2;
    };
    let agg = ["--avg", "--min", "--max"].into_iter().find(|f| flag(args, f));
    let mut sampler = blip_platform::Sampler::new();
    sampler.sample();
    std::thread::sleep(Duration::from_millis(1000));
    let mut values = Vec::new();
    let secs: u64 = if agg.is_some() {
        opt(args, "--seconds").and_then(|v| v.parse().ok()).unwrap_or(10)
    } else {
        0
    };
    let snap = sampler.sample();
    // Pings run on their own cadence; give them a moment for ping metrics.
    let snap = if m.id.starts_with("net.ping") || m.id == "net.routerping" {
        std::thread::sleep(Duration::from_millis(2500));
        sampler.sample()
    } else {
        snap
    };
    if let Some(v) = metrics::value(m.id, &snap) {
        values.push(v);
    }
    let end = std::time::Instant::now() + Duration::from_secs(secs);
    while std::time::Instant::now() < end {
        std::thread::sleep(Duration::from_secs(1));
        if let Some(v) = metrics::value(m.id, &sampler.sample()) {
            values.push(v);
        }
    }
    if values.is_empty() {
        eprintln!("{} isn't available on this PC right now.", m.title);
        return 3;
    }
    let v = match agg {
        Some("--avg") => values.iter().sum::<f64>() / values.len() as f64,
        Some("--min") => values.iter().copied().fold(f64::MAX, f64::min),
        Some("--max") => values.iter().copied().fold(f64::MIN, f64::max),
        _ => values[0],
    };
    if flag(args, "--raw") {
        println!("{v}");
    } else {
        println!("{}", metrics::format_value(m.unit, v));
    }
    0
}

fn trace(args: &[String]) -> i32 {
    let Some(host) = positional(args, 0) else {
        return usage();
    };
    let passes: u32 = opt(args, "--passes").and_then(|v| v.parse().ok()).unwrap_or(3);
    let t = blip_platform::net::Traceroute::new();
    if let Err(e) = t.start(host, None) {
        eprintln!("{e}");
        return 2;
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(30 * passes as u64 + 10);
    while t.snapshot().passes < passes && t.is_running() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(250));
    }
    t.stop();
    let snap = t.snapshot();
    if let Some(e) = snap.error {
        eprintln!("{e}");
        return 2;
    }
    if flag(args, "--json") {
        println!("{}", serde_json::to_string_pretty(&snap.hops).unwrap_or_default());
        return 0;
    }
    println!(
        "{:>3}  {:<40} {:>6} {:>8} {:>8} {:>8}",
        "#", "host", "loss", "avg", "best", "worst"
    );
    let f = |v: Option<f64>| v.map(|x| format!("{x:.1}")).unwrap_or_else(|| "—".into());
    for h in snap.hops {
        println!(
            "{:>3}  {:<40} {:>5.0}% {:>8} {:>8} {:>8}",
            h.hop,
            h.host,
            h.loss_pct,
            f(h.avg_ms),
            f(h.best_ms),
            f(h.worst_ms)
        );
    }
    0
}

fn speedtest(args: &[String], s: &Settings) -> i32 {
    let server = opt(args, "--server")
        .map(str::to_string)
        .unwrap_or_else(|| s.speed_test_open_speed_test_url.clone());
    let Some(base) = blip_core::speedtest::normalize_base(&server) else {
        eprintln!("No self-hosted OpenSpeedTest server set. Pass --server http://host:3000 (the public test runs from the Blip window).");
        return 2;
    };
    let tester = blip_core::speedtest::SpeedTester::new(
        std::sync::Arc::new(blip_platform::ping),
        Some(blip_core::paths::speed_history_file()),
    );
    eprintln!("Testing against {base}…");
    match tester.run_self_hosted_blocking(&base) {
        Ok(r) => {
            if flag(args, "--json") {
                println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
            } else {
                println!("Download  {}", fmt::throughput(r.down_mbps));
                println!(
                    "Upload    {}",
                    r.up_mbps.map(fmt::throughput).unwrap_or_else(|| "—".into())
                );
                println!(
                    "Ping      {} idle, {} loaded",
                    fmt::ms(r.ping_ms),
                    fmt::ms(r.loaded_ping_ms)
                );
                println!(
                    "{}",
                    blip_core::grades::share_line(&blip_core::grades::evaluate(
                        r.down_mbps,
                        r.up_mbps,
                        r.ping_ms,
                        r.loaded_ping_ms
                    ))
                );
            }
            0
        }
        Err(e) => {
            eprintln!("{e}");
            2
        }
    }
}

fn disktest(args: &[String], s: &Settings) -> i32 {
    let size: u32 = opt(args, "--size")
        .and_then(|v| v.parse().ok())
        .unwrap_or(s.disk_speed_size);
    if ![128, 512, 1024].contains(&size) {
        eprintln!("--size must be 128, 512 or 1024");
        return 2;
    }
    let dir = opt(args, "--path")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let tester = blip_core::disktest::DiskTester::new(Some(blip_core::paths::disk_history_file()));
    eprintln!("Testing {} with {size} MB…", dir.display());
    match tester.run_blocking(size, &dir) {
        Ok(Some(r)) => {
            if flag(args, "--json") {
                println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
            } else {
                println!("Write   {:.0} MB/s", r.write_mbps);
                println!("Read    {:.0} MB/s", r.read_mbps);
                if let Some(i) = r.random_read_iops {
                    println!("4K read {i:.0} IOPS");
                }
            }
            0
        }
        Ok(None) => 1,
        Err(e) => {
            eprintln!("{e}");
            2
        }
    }
}

fn bench(args: &[String]) -> i32 {
    let profile = if flag(args, "--quick") {
        Profile::Quick
    } else {
        Profile::Full
    };
    let snap = blip_platform::snapshot_once(Duration::from_millis(10));
    let model = if snap.system.model.is_empty() {
        snap.cpu.model.clone()
    } else {
        snap.system.model.clone()
    };
    let engine = BenchEngine::new(
        std::sync::Arc::new(blip_core::bench::engine::NullThermal),
        blip_platform::gpu_compute(),
        model,
        format!("{} {}", snap.system.os_name, snap.system.os_version),
        Some(blip_core::paths::bench_history_file()),
    );
    eprintln!(
        "Running Blip Bench ({})…",
        if profile == Profile::Full {
            "about 90 s"
        } else {
            "about 6 s"
        }
    );
    let Some(r) = engine.run_blocking(profile) else {
        eprintln!("The benchmark didn't finish.");
        return 2;
    };
    if flag(args, "--json") {
        println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
        return 0;
    }
    println!("Blip Bench   {:.0}", r.composite);
    println!("Single-core  {:.0}", r.single_core.score);
    println!("All cores    {:.0}", r.multi_core.score);
    println!("Memory       {:.0}", r.memory.score);
    if let Some(g) = &r.gpu {
        println!("GPU          {:.0}", g.score);
    }
    if let Some(l) = r.throttle_percent_lost() {
        println!("Sustained    −{l}%");
    }
    0
}

fn awake(args: &[String]) -> i32 {
    let minutes: u64 = positional(args, 0).and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut k = blip_platform::KeepAwake::new();
    k.engage(blip_platform::AwakeOptions {
        keep_display_on: flag(args, "--display"),
        ignore_lid: false,
        jiggle: false,
    });
    if let Some(e) = &k.last_error {
        eprintln!("{e}");
        return 2;
    }
    if minutes == 0 {
        eprintln!("Keeping this PC awake — press Ctrl+C to stop.");
        loop {
            std::thread::sleep(Duration::from_secs(3600));
        }
    }
    eprintln!("Keeping this PC awake for {minutes} min…");
    std::thread::sleep(Duration::from_secs(minutes * 60));
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn positional_skips_option_values() {
        let a: Vec<String> = ["metric", "--seconds", "5", "cpu.usage", "--avg"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(positional(&a, 0), Some("metric"));
        assert_eq!(positional(&a, 1), Some("cpu.usage"));
        assert_eq!(opt(&a, "--seconds"), Some("5"));
    }
}
