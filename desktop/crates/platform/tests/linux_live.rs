//! Live checks of every Linux-native source, run on real Linux (CI's ubuntu x64 and arm64
//! runners, as an ordinary user, and inside Rocky 8 / Debian / Arch containers). They assert
//! shape and sanity — a runner has no battery, no GPU and no Wi-Fi — and print what each source
//! returned so the CI log doubles as a capability report.
#![cfg(target_os = "linux")]

use std::time::{Duration, Instant};

use blip_platform::linux;

#[test]
fn sampler_reads_this_machine() {
    let mut s = blip_platform::Sampler::new();
    s.sample();
    // Generate a little disk traffic so the I/O deltas have something to see.
    let tmp = std::env::temp_dir().join("blip-live-io");
    std::fs::write(&tmp, vec![7u8; 4 << 20]).unwrap();
    let _ = std::fs::File::open(&tmp).and_then(|f| f.sync_all());
    std::thread::sleep(Duration::from_millis(1500));
    let snap = s.sample();
    let _ = std::fs::remove_file(&tmp);
    println!(
        "cpu {:?}",
        (
            snap.cpu.total,
            snap.cpu.user,
            snap.cpu.system,
            &snap.cpu.model,
            snap.cpu.physical_cores,
            snap.cpu.performance_cores,
            snap.cpu.efficiency_cores,
            snap.cpu.performance_pct,
            snap.cpu.frequency_mhz,
            snap.cpu.load
        )
    );
    println!("memory {:?}", snap.memory);
    println!("volumes {:?}", snap.disk.volumes);
    println!(
        "disk io {} / {} active {:?} totals {} / {}",
        snap.disk.read_bps,
        snap.disk.write_bps,
        snap.disk.active_pct,
        snap.disk.total_read,
        snap.disk.total_written
    );
    println!("drives {:#?}", snap.disk.drives);
    println!("gpu {:?}", snap.gpu);
    println!("thermal {:?}", snap.thermal);
    println!("battery {:?}", snap.battery);
    println!(
        "network primary={:?} router={:?} metered={} vpn={:?}",
        snap.network.primary, snap.network.router_ip, snap.network.metered, snap.network.vpn
    );
    for i in &snap.network.interfaces {
        println!(
            "  if {} {:?} v4={:?} gw={:?} dns={:?} speed={:?} up={}",
            i.name, i.kind, i.ipv4, i.gateway, i.dns, i.link_speed_bps, i.is_up
        );
    }
    println!("system {:?}", snap.system);
    println!(
        "top cpu {:?}",
        snap.top_cpu
            .iter()
            .map(|p| (&p.name, p.cpu, p.user_owned))
            .collect::<Vec<_>>()
    );

    assert!(snap.cpu.logical_cores > 0);
    assert!(snap.cpu.physical_cores > 0);
    assert!((0.0..=100.0).contains(&snap.cpu.total));
    assert!(snap.cpu.user + snap.cpu.system <= 100.5, "user+kernel within 100");
    assert!(!snap.cpu.model.is_empty(), "CPU model");
    assert!(snap.cpu.load.is_some(), "Linux has real load averages");
    assert!(snap.memory.total > 0 && snap.memory.available <= snap.memory.total);
    assert!(snap.memory.cached > 0, "page cache from /proc/meminfo");
    assert!(snap.disk.volumes.iter().any(|v| v.is_system), "root volume");
    assert!(
        snap.disk.total_read > 0,
        "since-boot disk totals from /proc/diskstats"
    );
    assert!(snap.disk.active_pct.is_some(), "disk active time");
    assert!(!snap.system.os_name.is_empty() && snap.system.uptime_secs > 0);
    assert!(!snap.top_memory.is_empty());
    assert!(
        snap.top_memory.iter().any(|p| p.user_owned),
        "own processes are marked"
    );
    let volumes: Vec<_> = snap.disk.volumes.iter().map(|v| &v.mount).collect();
    assert!(
        !volumes.iter().any(|m| m.starts_with("/snap/")),
        "snap squashfs mounts hidden"
    );
}

#[test]
fn ping_sockets_and_traceroute() {
    println!("ping sockets available: {}", linux::icmp::available());
    if !linux::icmp::available() {
        println!("net.ipv4.ping_group_range excludes this user; Blip falls back to ping(8).");
        return;
    }
    let lo = "127.0.0.1".parse().unwrap();
    let r = linux::icmp::echo(lo, None, 1000).expect("echo");
    assert!(r.reached, "loopback answers");
    println!("loopback rtt {:?}", r.rtt_ms);
    // A TTL-limited probe to loopback still reaches it (one hop).
    let r = linux::icmp::echo(lo, Some(1), 1000).expect("echo ttl");
    assert!(r.reached);
    // Through the shared API too.
    assert!(blip_platform::ping("127.0.0.1").is_some());
    // A real route, when the runner has one (containers and some sandboxes don't).
    if let Some(ip) = blip_platform::net::resolve("1.1.1.1") {
        let hop1 = linux::icmp::echo(ip, Some(1), 1500);
        println!(
            "hop 1 towards 1.1.1.1: {:?}",
            hop1.as_ref().map(|h| (h.from, h.rtt_ms, h.reached))
        );
    }
}

#[test]
fn traceroute_session_reaches_loopback() {
    if !linux::icmp::available() {
        return;
    }
    let t = blip_platform::net::Traceroute::new();
    t.start("127.0.0.1", None).unwrap();
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(10) {
        let s = t.snapshot();
        if s.passes > 0 {
            println!("{:?}", s.hops);
            assert_eq!(s.hops.len(), 1);
            t.stop();
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    panic!("no traceroute pass in 10 s");
}

#[test]
fn identity_and_topology() {
    println!("model {:?}", linux::system::model());
    println!("cpu model {:?}", linux::system::cpu_model());
    println!("topology {:?}", linux::system::core_topology());
    println!("clocks {:?}", linux::hwmon::cpu_clocks());
    println!("sensors {:?}", linux::hwmon::read_sensors());
    println!("language {}", blip_platform::ui_language());
    println!("fonts {:?}", blip_platform::system_fonts());
    println!("tray host {}", blip_platform::tray_host_available());
    println!("lid {}", blip_platform::KeepAwake::lid_supported());
    println!("jiggle {}", blip_platform::KeepAwake::jiggle_supported());
    println!("work area {:?}", blip_platform::work_area());
    let (phys, p, e) = linux::system::core_topology();
    assert!(phys > 0 && p + e == phys);
}

#[test]
fn launch_at_login_round_trip() {
    let dir = std::env::temp_dir().join(format!("blip-xdg-{}", std::process::id()));
    std::env::set_var("XDG_CONFIG_HOME", &dir);
    blip_platform::set_launch_at_login(true).unwrap();
    assert!(blip_platform::launch_at_login());
    let entry = std::fs::read_to_string(dir.join("autostart/com.blainemiller.Blip.desktop")).unwrap();
    assert!(entry.contains("--background"));
    blip_platform::set_launch_at_login(false).unwrap();
    assert!(!blip_platform::launch_at_login());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn gpu_bench_leg_is_bounded() {
    // Runners have no GPU (only llvmpipe/lavapipe, which the leg refuses); a real GPU scores.
    let start = Instant::now();
    let r = blip_platform::gpu_compute().and_then(|g| g.matmul(1.0, &|| false));
    println!(
        "gpu leg {:?} in {:?}",
        r.as_ref().map(|r| r.value),
        start.elapsed()
    );
    assert!(start.elapsed() < Duration::from_secs(20));
}

#[test]
fn keep_awake_engages_where_logind_runs() {
    let mut k = blip_platform::KeepAwake::new();
    k.engage(blip_platform::AwakeOptions {
        keep_display_on: true,
        ignore_lid: false,
        jiggle: false,
    });
    println!("keep awake error: {:?}", k.last_error);
    k.release();
    assert!(k.active().is_none());
}
