//! Score model — a straight port of `BenchScore.swift`. The reference constants are the FROZEN
//! Blip 2.0 unit system shared with the Mac and iPhone: never retune them.

use serde::{Deserialize, Serialize};

use super::workloads::WorkloadResult;

pub fn reference(id: &str) -> Option<f64> {
    Some(match id {
        "cpu.sha256" => 1500.0,
        "cpu.lzfse" => 500.0,
        "cpu.json" => 300.0,
        "cpu.fft" => 2000.0,
        "mem.bandwidth" => 60.0,
        "mem.latency" => 100.0,
        "gpu.matmul" => 2000.0,
        "npu.featureprint" => 50.0,
        _ => return None,
    })
}

pub fn lower_is_better(id: &str) -> bool {
    id == "mem.latency"
}

pub fn normalized(r: &WorkloadResult) -> Option<f64> {
    let rf = reference(&r.id)?;
    if r.value <= 0.0 {
        return None;
    }
    Some(if lower_is_better(&r.id) {
        rf / r.value
    } else {
        r.value / rf
    })
}

/// Geometric mean of the normalized workloads × 1000, missing legs ignored.
pub fn composite(results: &[WorkloadResult]) -> f64 {
    let norms: Vec<f64> = results.iter().filter_map(normalized).collect();
    if norms.is_empty() {
        return 0.0;
    }
    (norms.iter().map(|n| n.ln()).sum::<f64>() / norms.len() as f64).exp() * 1000.0
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CategoryScore {
    pub name: String,
    pub score: f64,
    pub results: Vec<WorkloadResult>,
}

pub fn category(name: &str, results: Vec<WorkloadResult>) -> CategoryScore {
    CategoryScore {
        name: name.into(),
        score: composite(&results),
        results,
    }
}

/// The headline number: geometric mean of the category scores that exist.
pub fn overall(categories: &[Option<&CategoryScore>]) -> f64 {
    let scores: Vec<f64> = categories
        .iter()
        .flatten()
        .map(|c| c.score)
        .filter(|s| *s > 0.0)
        .collect();
    if scores.is_empty() {
        return 0.0;
    }
    (scores.iter().map(|s| s.ln()).sum::<f64>() / scores.len() as f64).exp()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ThermalSample {
    pub at_seconds: f64,
    pub temperature_c: Option<f64>,
    pub fan_rpm: Option<f64>,
    /// 0 nominal … 3 critical.
    pub thermal_state: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Profile {
    /// ~90 s: burst legs + 45 s sustained with thermal sampling.
    Full,
    /// ~6 s, no sustained phase — the QA path.
    Quick,
}

impl Profile {
    pub fn per_workload_seconds(self) -> f64 {
        match self {
            Profile::Full => 2.5,
            Profile::Quick => 0.5,
        }
    }
    pub fn sustained_seconds(self) -> f64 {
        match self {
            Profile::Full => 45.0,
            Profile::Quick => 0.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BenchResult {
    /// Unix seconds.
    pub date: u64,
    pub profile: Profile,
    pub single_core: CategoryScore,
    pub multi_core: CategoryScore,
    pub memory: CategoryScore,
    pub gpu: Option<CategoryScore>,
    pub neural: Option<CategoryScore>,
    /// Sustained ÷ burst multicore. 1.0 = no throttle.
    pub throttle_factor: Option<f64>,
    pub thermal_samples: Vec<ThermalSample>,
    pub composite: f64,
    pub device_model: String,
    pub os_version: String,
}

impl BenchResult {
    pub fn throttle_percent_lost(&self) -> Option<i64> {
        self.throttle_factor
            .map(|f| (((1.0 - f) * 100.0).round() as i64).max(0))
    }
}

#[cfg(test)]
mod tests {
    use super::super::workloads::BenchUnit;
    use super::*;

    #[test]
    fn reference_values_score_1000() {
        let r = vec![
            WorkloadResult::new("cpu.sha256", 1500.0, BenchUnit::MbPerSec),
            WorkloadResult::new("mem.latency", 100.0, BenchUnit::NsPerAccess),
        ];
        assert!((composite(&r) - 1000.0).abs() < 1e-9);
    }

    #[test]
    fn latency_inverts_and_missing_legs_drop_out() {
        let r = vec![
            WorkloadResult::new("mem.latency", 50.0, BenchUnit::NsPerAccess),
            WorkloadResult::new("gpu.matmul", 0.0, BenchUnit::Gflops),
        ];
        assert!((composite(&r) - 2000.0).abs() < 1e-9);
        let a = category(
            "A",
            vec![WorkloadResult::new("cpu.fft", 4000.0, BenchUnit::FftPerSec)],
        );
        assert!((overall(&[Some(&a), None]) - 2000.0).abs() < 1e-9);
    }
}
