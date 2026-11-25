//! Live checks of every Windows-native source, run on a real Windows machine (CI's
//! windows-latest / windows-11-arm runners, as a standard user). They assert shape and sanity —
//! a runner has no battery and no GPU — and print what each source returned so the CI log
//! doubles as a capability report.
#![cfg(windows)]

use std::time::Duration;

#[test]
fn sampler_reads_this_pc() {
    let mut s = blip_platform::Sampler::new();
    s.sample();
    std::thread::sleep(Duration::from_millis(1500));
    let snap = s.sample();
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
            snap.cpu.frequency_mhz
        )
    );
    println!("memory {:?}", snap.memory);
    println!("volumes {:?}", snap.disk.volumes);
    println!(
        "disk io {} / {} active {:?}",
        snap.disk.read_bps, snap.disk.write_bps, snap.disk.active_pct
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
            "  if {} {:?} {:?} v4={:?} gw={:?} speed={:?}",
            i.name, i.kind, i.description, i.ipv4, i.gateway, i.link_speed_bps
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
    assert!((0.0..=100.0).contains(&snap.cpu.total));
    assert!(snap.cpu.user + snap.cpu.system <= 100.5, "user+kernel within 100");
    assert!(!snap.cpu.model.is_empty(), "CPU name from the registry");
    assert!(snap.cpu.physical_cores > 0 && snap.cpu.physical_cores <= snap.cpu.logical_cores);
    assert!(snap.memory.total > 0 && snap.memory.used <= snap.memory.total);
    assert!(
        snap.memory.commit_limit >= snap.memory.total,
        "commit counters from PDH"
    );
    assert!(
        snap.disk.volumes.iter().any(|v| v.is_system),
        "system drive found"
    );
    assert!(
        snap.system.os_name.starts_with("Windows"),
        "{}",
        snap.system.os_name
    );
    assert!(snap.system.uptime_secs > 0);
    assert!(!snap.network.interfaces.is_empty(), "an adapter is up");
    assert!(snap.network.connected);
    assert!(!snap.top_memory.is_empty());
}

#[test]
fn icmp_ping_and_traceroute_without_admin() {
    // Loopback always answers; public hosts may be filtered on CI, so only report them.
    let local = blip_platform::ping("127.0.0.1");
    println!("ping 127.0.0.1 = {local:?}");
    assert!(local.is_some(), "IcmpSendEcho2 works unprivileged");
    println!("ping 1.1.1.1 = {:?}", blip_platform::ping("1.1.1.1"));
    let t = blip_platform::net::Traceroute::new();
    t.start("127.0.0.1", None).unwrap();
    for _ in 0..40 {
        if t.snapshot().passes >= 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    t.stop();
    let s = t.snapshot();
    println!("trace {:?}", s.hops);
    assert_eq!(s.hops.first().map(|h| h.host.as_str()), Some("127.0.0.1"));
}

#[test]
fn keep_awake_request_and_release() {
    let mut k = blip_platform::KeepAwake::new();
    k.engage(blip_platform::AwakeOptions {
        keep_display_on: true,
        ignore_lid: false,
        jiggle: false,
    });
    assert!(k.last_error.is_none(), "{:?}", k.last_error);
    assert!(k.active().is_some());
    println!("lid supported: {}", blip_platform::KeepAwake::lid_supported());
    k.release();
    assert!(k.active().is_none());
}

#[test]
fn kills_own_child_but_not_system() {
    let mut child = std::process::Command::new("cmd")
        .args(["/c", "ping -n 30 127.0.0.1 >NUL"])
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(300));
    blip_platform::kill_process(child.id()).expect("own process");
    assert!(child.wait().is_ok());
    assert!(blip_platform::kill_process(4).is_err(), "System (pid 4) refused");
}

#[test]
fn exe_icon_and_identity() {
    let notepad = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into()) + "\\explorer.exe";
    let icon = blip_platform::exe_icon(&notepad);
    assert!(
        icon.as_ref()
            .is_some_and(|(w, h, px)| *w == 16 && *h == 16 && px.iter().any(|b| *b != 0)),
        "icon pixels"
    );
    println!("ui language {:?}", blip_platform::ui_language());
    let fonts = blip_platform::system_fonts();
    println!("fonts {fonts:?}");
    assert!(fonts.ui.is_some(), "Segoe UI present");
}

#[test]
fn launch_at_login_round_trip() {
    let before = blip_platform::launch_at_login();
    blip_platform::set_launch_at_login(true).unwrap();
    assert!(blip_platform::launch_at_login());
    blip_platform::set_launch_at_login(before).unwrap();
    assert_eq!(blip_platform::launch_at_login(), before);
}

#[test]
fn gpu_bench_leg_runs_or_drops_out() {
    // Runners have no GPU, only Microsoft's software adapter: the leg must drop out, fast.
    let start = std::time::Instant::now();
    let r = blip_platform::gpu_compute().and_then(|g| g.matmul(0.5, &|| false));
    assert!(
        start.elapsed() < Duration::from_secs(15),
        "GPU leg took {:?}",
        start.elapsed()
    );
    println!("gpu.matmul = {r:?}");
    if let Some(r) = r {
        assert!(r.value > 0.0);
    }
}

#[test]
fn uncached_disk_test_on_the_system_drive() {
    let r = blip_core::disktest::run(128, &std::env::temp_dir(), &|_, _| {}, &|| false)
        .expect("FILE_FLAG_NO_BUFFERING I/O")
        .expect("result");
    println!("disk test {r:?}");
    assert!(r.write_mbps > 0.0 && r.read_mbps > 0.0);
}

/// The map download exactly as the Network panel runs it: https, gunzip, open, look up.
#[test]
fn geoip_database_downloads_and_answers() {
    use blip_core::geoip::{GeoDb, GeoStatus};
    let dir = std::env::temp_dir().join(format!("blip-geo-{}", std::process::id()));
    std::env::set_var("BLIP_DATA_DIR", &dir);
    let db = GeoDb::new();
    db.download(None);
    let start = std::time::Instant::now();
    loop {
        match db.status() {
            GeoStatus::Ready { kind, .. } => {
                println!("database ready: {kind} in {:?}", start.elapsed());
                break;
            }
            GeoStatus::Failed(e) => panic!("download failed: {e}"),
            _ => assert!(start.elapsed().as_secs() < 600, "download timed out"),
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let point = db.lookup("8.8.8.8").expect("lookup");
    println!("8.8.8.8 → {point:?}");
    println!("public address lookup ok: {}", blip_core::wan_ip().is_some());
    db.remove();
    let _ = std::fs::remove_dir_all(dir);
}
