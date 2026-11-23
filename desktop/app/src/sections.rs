//! The popover's rows — the same sections, in the same order, as the Mac.

use blip_core::Icon;

use crate::theme::Category;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Section {
    Cpu,
    Memory,
    Disk,
    Network,
    Gpu,
    Thermal,
    Bench,
    Battery,
    Awake,
}

impl Section {
    pub fn title(self) -> String {
        blip_core::t(match self {
            Section::Cpu => "CPU",
            Section::Memory => "Memory",
            Section::Disk => "Disk",
            Section::Network => "Network",
            Section::Gpu => "GPU",
            Section::Thermal => "Thermal",
            Section::Bench => "Bench",
            Section::Battery => "Battery",
            Section::Awake => "Awake",
        })
    }

    pub fn icon(self) -> Icon {
        match self {
            Section::Cpu => Icon::Cpu,
            Section::Memory => Icon::Memory,
            Section::Disk => Icon::Disk,
            Section::Network => Icon::Wifi,
            Section::Gpu => Icon::Gpu,
            Section::Thermal => Icon::Thermometer,
            Section::Bench => Icon::Bench,
            Section::Battery => Icon::Battery,
            Section::Awake => Icon::Awake,
        }
    }

    pub fn category(self) -> Category {
        match self {
            Section::Cpu => Category::Cpu,
            Section::Memory => Category::Memory,
            Section::Disk => Category::Disk,
            Section::Network => Category::Network,
            Section::Gpu => Category::Gpu,
            Section::Thermal => Category::Thermal,
            Section::Bench => Category::Bench,
            Section::Battery => Category::Battery,
            Section::Awake => Category::Awake,
        }
    }

    pub fn key(self) -> &'static str {
        match self {
            Section::Cpu => "cpu",
            Section::Memory => "memory",
            Section::Disk => "disk",
            Section::Network => "network",
            Section::Gpu => "gpu",
            Section::Thermal => "thermal",
            Section::Bench => "bench",
            Section::Battery => "battery",
            Section::Awake => "awake",
        }
    }
}

pub const ALL: [Section; 9] = [
    Section::Cpu,
    Section::Memory,
    Section::Disk,
    Section::Network,
    Section::Gpu,
    Section::Thermal,
    Section::Bench,
    Section::Battery,
    Section::Awake,
];
