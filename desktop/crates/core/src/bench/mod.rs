//! BenchKit for Windows/Linux: the same legs, references and score model as the Mac and iPhone.

pub mod engine;
pub mod score;
pub mod workloads;

pub use engine::{BenchEngine, BenchState, GpuCompute, LiveLeg, Phase, ThermalSource};
pub use score::{BenchResult, CategoryScore, Profile, ThermalSample};
pub use workloads::{BenchUnit, WorkloadResult};
