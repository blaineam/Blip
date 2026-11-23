//! A believable Windows laptop for screenshots, UI tests and `Blip.exe --demo`.

use blip_core::model::*;

use crate::state::Histories;

#[allow(clippy::field_reassign_with_default)]
pub fn snapshot() -> Snapshot {
    let mut s = Snapshot::default();
    s.cpu = CpuStats {
        total: 31.0,
        user: 22.0,
        system: 9.0,
        cores: vec![
            48.0, 12.0, 35.0, 8.0, 61.0, 22.0, 15.0, 4.0, 27.0, 9.0, 33.0, 18.0, 6.0, 41.0, 11.0, 3.0,
        ],
        load: Some([2.41, 2.10, 1.87]),
        physical_cores: 10,
        logical_cores: 16,
        performance_cores: 2,
        efficiency_cores: 8,
        model: "13th Gen Intel(R) Core(TM) i7-1365U".into(),
        performance_pct: Some(112.0),
        frequency_mhz: Some(3360),
    };
    let gb = 1_073_741_824u64;
    s.memory = MemoryStats {
        total: 32 * gb,
        used: 17 * gb,
        available: 15 * gb,
        cached: 9 * gb,
        compressed: None,
        committed: 21 * gb,
        commit_limit: 36 * gb,
        paged_pool: Some(780 * 1_048_576),
        nonpaged_pool: Some(410 * 1_048_576),
        swap_used: gb / 2,
        swap_total: 4 * gb,
        pressure: 0,
    };
    s.disk = DiskStats {
        volumes: vec![
            Volume {
                name: "Windows".into(),
                mount: "C:\\".into(),
                file_system: "NTFS".into(),
                total: 1_000_000_000_000,
                free: 610_000_000_000,
                removable: false,
                is_system: true,
            },
            Volume {
                name: "Backup".into(),
                mount: "E:\\".into(),
                file_system: "exFAT".into(),
                total: 2_000_000_000_000,
                free: 1_240_000_000_000,
                removable: true,
                is_system: false,
            },
        ],
        read_bps: 18_400_000,
        write_bps: 4_200_000,
        total_read: 41_200_000_000,
        total_written: 9_800_000_000,
        active_pct: Some(6.0),
        drives: vec![DriveHealth {
            id: "0".into(),
            name: "Samsung SSD 990 PRO 1TB".into(),
            bus: "NVMe".into(),
            media: "SSD".into(),
            is_internal: true,
            smart_status: "Verified".into(),
            percentage_used: Some(3),
            available_spare: Some(100),
            available_spare_threshold: Some(10),
            temperature_c: Some(41),
            bytes_written: Some(28_600_000_000_000),
            bytes_read: Some(39_100_000_000_000),
            power_on_hours: Some(4_321),
            power_cycles: Some(1_204),
            unsafe_shutdowns: Some(37),
            media_errors: Some(0),
            critical_warning: Some(0),
        }],
    };
    s.gpu = GpuStats {
        name: "Intel(R) Iris(R) Xe Graphics".into(),
        utilization: 14.0,
        temperature_c: None,
        dedicated_used: Some(512 * 1_048_576),
        dedicated_total: Some(gb),
        shared_used: Some(2 * gb),
        engines: vec![
            ("3D".into(), 14.0),
            ("Video Decode".into(), 6.0),
            ("Copy".into(), 1.0),
        ],
        available: true,
    };
    s.network = NetworkStats {
        connected: true,
        primary: Some("12".into()),
        down_bps: 4_200_000,
        up_bps: 680_000,
        total_down: 412_000_000_000,
        total_up: 88_000_000_000,
        ping_ms: Some(11.0),
        router_ping_ms: Some(2.0),
        router_ip: Some("192.168.1.1".into()),
        interfaces: vec![Interface {
            id: "12".into(),
            name: "Wi-Fi".into(),
            description: "Intel(R) Wi-Fi 6E AX211 160MHz".into(),
            kind: InterfaceKind::WiFi,
            ipv4: vec!["192.168.1.42".into()],
            ipv6: vec!["2001:db8::42".into()],
            mac: "3C:22:FB:12:34:56".into(),
            gateway: Some("192.168.1.1".into()),
            dns: vec!["192.168.1.1".into()],
            link_speed_bps: Some(1_201_000_000),
            is_up: true,
            ssid: Some("Home".into()),
            signal_pct: Some(88),
        }],
        vpn: None,
        metered: false,
    };
    s.battery = BatteryStats {
        present: true,
        level: 84.0,
        charging: false,
        plugged_in: false,
        health_pct: Some(93.0),
        cycle_count: Some(212),
        design_capacity_mwh: Some(57_000),
        full_capacity_mwh: Some(53_010),
        temperature_c: Some(31.0),
        minutes_remaining: Some(312),
        rate_mw: Some(-7_400),
        chemistry: Some("LiP".into()),
        battery_saver: false,
    };
    s.thermal = ThermalStats {
        cpu_c: Some(52.0),
        gpu_c: None,
        zones: vec![("TZ00".into(), 52.0)],
        fans: vec![],
        level: ThermalLevel::Nominal,
        throttling: false,
    };
    s.system = SystemInfo {
        uptime_secs: 3 * 86_400 + 5 * 3600,
        model: "ThinkPad X1 Carbon Gen 11".into(),
        manufacturer: "LENOVO".into(),
        os_name: "Windows 11 Pro".into(),
        os_version: "24H2 (26100.2605)".into(),
        host_name: "LAPTOP".into(),
        blip_memory: 41 * 1_048_576,
        blip_cpu: 0.4,
    };
    let p = |pid, name: &str, cpu, mb: u64| ProcessInfo {
        pid,
        name: name.into(),
        cpu,
        memory: mb * 1_048_576,
        exe: None,
        user_owned: true,
    };
    s.top_cpu = vec![
        p(1, "msedge.exe", 12.4, 1840),
        p(2, "Code.exe", 6.1, 960),
        p(3, "Teams.exe", 4.3, 720),
        p(4, "explorer.exe", 1.2, 210),
        p(5, "Spotify.exe", 0.9, 330),
    ];
    s.top_memory = vec![
        p(1, "msedge.exe", 12.4, 1840),
        p(2, "Code.exe", 6.1, 960),
        p(3, "Teams.exe", 4.3, 720),
        p(5, "Spotify.exe", 0.9, 330),
        p(4, "explorer.exe", 1.2, 210),
    ];
    s
}

pub fn histories() -> Histories {
    let mut h = Histories::default();
    for i in 0..60 {
        let x = i as f64;
        h.cpu.push(28.0 + 14.0 * (x / 6.0).sin() + 6.0 * (x / 2.3).cos());
        h.memory.push(52.0 + 2.0 * (x / 15.0).sin());
        h.gpu.push(10.0 + 8.0 * (x / 5.0).sin().abs());
        h.disk_read.push(1e7 * (1.2 + (x / 4.0).sin()).max(0.1));
        h.disk_write.push(3e6 * (1.1 + (x / 7.0).cos()).max(0.1));
        h.net_down
            .push(5e6 * (1.3 + (x / 5.0).sin() + 0.4 * (x / 1.7).cos()).max(0.1));
        h.net_up.push(8e5 * (1.2 + (x / 3.0).cos()).max(0.1));
    }
    h
}
