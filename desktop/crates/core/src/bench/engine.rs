//! The orchestrator, ported from `BenchEngine.swift`: single-core mix → all-core mix → memory →
//! GPU → (neural: Mac only) → sustained phase with thermal sampling. Runs on a worker thread and
//! publishes into a shared `BenchState` the UI polls each frame.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use super::score::{self, BenchResult, CategoryScore, Profile, ThermalSample};
use super::workloads::{self, BenchUnit, WorkloadResult};
use crate::i18n::t;

/// Best-effort live thermals for the sustained phase.
pub trait ThermalSource: Send + Sync {
    fn temperature_c(&self) -> Option<f64>;
    fn fan_rpm(&self) -> Option<f64>;
    /// 0 nominal … 3 critical.
    fn thermal_state(&self) -> i32;
}

/// The GPU leg: 1024³ single-precision GEMM throughput, in GFLOPS. Platforms implement it with
/// their native compute API (Direct3D 11 on Windows); `None` = the category drops out.
pub trait GpuCompute: Send + Sync {
    fn matmul(&self, seconds: f64, cancelled: &(dyn Fn() -> bool + Sync)) -> Option<WorkloadResult>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Phase {
    #[default]
    Idle,
    SingleCore,
    MultiCore,
    Memory,
    Gpu,
    Neural,
    Sustained,
    Done,
}

impl Phase {
    pub fn label(self) -> String {
        t(match self {
            Phase::Idle => "Idle",
            Phase::SingleCore => "CPU · single-core",
            Phase::MultiCore => "CPU · all cores",
            Phase::Memory => "Memory",
            Phase::Gpu => "GPU",
            Phase::Neural => "Neural",
            Phase::Sustained => "Sustained + thermals",
            Phase::Done => "Done",
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct LiveLeg {
    /// "single" / "multi" / "memory" / "gpu" / "sustained".
    pub id: &'static str,
    pub name: String,
    /// Category units; for "sustained", % of the first bucket.
    pub score: f64,
}

#[derive(Debug, Clone, Default)]
pub struct BenchState {
    pub running: bool,
    pub phase: Phase,
    pub progress: f64,
    pub live_legs: Vec<LiveLeg>,
    pub live_thermal: Option<ThermalSample>,
    pub last_result: Option<BenchResult>,
    pub history: Vec<BenchResult>,
}

pub const MAX_HISTORY: usize = 30;

#[derive(Clone)]
pub struct BenchEngine {
    state: Arc<Mutex<BenchState>>,
    cancel: Arc<AtomicBool>,
    thermal: Arc<dyn ThermalSource>,
    gpu: Option<Arc<dyn GpuCompute>>,
    device_model: String,
    os_version: String,
    history_path: Option<std::path::PathBuf>,
}

impl BenchEngine {
    pub fn new(
        thermal: Arc<dyn ThermalSource>,
        gpu: Option<Arc<dyn GpuCompute>>,
        device_model: String,
        os_version: String,
        history_path: Option<std::path::PathBuf>,
    ) -> Self {
        let history: Vec<BenchResult> = history_path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        let state = BenchState {
            last_result: history.last().cloned(),
            history,
            ..Default::default()
        };
        Self {
            state: Arc::new(Mutex::new(state)),
            cancel: Arc::new(AtomicBool::new(false)),
            thermal,
            gpu,
            device_model,
            os_version,
            history_path,
        }
    }

    pub fn state(&self) -> BenchState {
        self.state.lock().unwrap().clone()
    }

    pub fn is_running(&self) -> bool {
        self.state.lock().unwrap().running
    }

    pub fn personal_best(&self) -> Option<f64> {
        let s = self.state.lock().unwrap();
        s.history
            .iter()
            .filter(|r| r.profile == Profile::Full)
            .map(|r| r.composite)
            .reduce(f64::max)
    }

    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    pub fn toggle(&self, profile: Profile) {
        if self.is_running() {
            self.cancel()
        } else {
            self.start(profile, None)
        }
    }

    /// Starts a run on a worker thread. `on_change` fires whenever published state moves
    /// (the UI uses it to request a repaint). Returns immediately.
    pub fn start(&self, profile: Profile, on_change: Option<Arc<dyn Fn() + Send + Sync>>) {
        {
            let mut s = self.state.lock().unwrap();
            if s.running {
                return;
            }
            s.running = true;
            s.phase = Phase::SingleCore;
            s.progress = 0.0;
            s.live_legs.clear();
            s.live_thermal = None;
        }
        self.cancel.store(false, Ordering::Relaxed);
        let me = self.clone();
        std::thread::Builder::new()
            .name("blip-bench".into())
            .spawn(move || {
                let result = me.run(profile, on_change.as_deref());
                me.finish(result);
                if let Some(f) = on_change {
                    f();
                }
            })
            .expect("spawn bench thread");
    }

    /// Blocking run (the CLI's `blip bench`): returns the result, also recorded in history.
    pub fn run_blocking(&self, profile: Profile) -> Option<BenchResult> {
        {
            let mut s = self.state.lock().unwrap();
            if s.running {
                return None;
            }
            s.running = true;
        }
        self.cancel.store(false, Ordering::Relaxed);
        let r = self.run(profile, None);
        self.finish(r.clone());
        r
    }

    fn finish(&self, result: Option<BenchResult>) {
        let mut s = self.state.lock().unwrap();
        s.running = false;
        s.phase = if result.is_some() {
            Phase::Done
        } else {
            Phase::Idle
        };
        s.progress = if result.is_some() { 1.0 } else { 0.0 };
        if let Some(r) = result {
            s.last_result = Some(r.clone());
            s.history.push(r);
            let excess = s.history.len().saturating_sub(MAX_HISTORY);
            s.history.drain(..excess);
            if let Some(p) = &self.history_path {
                if let Some(dir) = p.parent() {
                    let _ = std::fs::create_dir_all(dir);
                }
                if let Ok(json) = serde_json::to_vec(&s.history) {
                    let _ = crate::paths::write_atomic(p, &json);
                }
            }
        }
    }

    fn publish(&self, f: impl FnOnce(&mut BenchState), on_change: Option<&(dyn Fn() + Send + Sync)>) {
        f(&mut self.state.lock().unwrap());
        if let Some(cb) = on_change {
            cb();
        }
    }

    fn run(&self, profile: Profile, on_change: Option<&(dyn Fn() + Send + Sync)>) -> Option<BenchResult> {
        let cancel = self.cancel.clone();
        let cancelled = move || cancel.load(Ordering::Relaxed);
        let t = profile.per_workload_seconds();
        let sustained_weight = if profile.sustained_seconds() > 0.0 {
            0.45
        } else {
            0.0
        };
        let leg_weight = (1.0 - sustained_weight) / 5.0;
        let mut progress: f64 = 0.0;
        let mut step = |me: &Self, phase: Phase, leg: Option<LiveLeg>| {
            progress += leg_weight;
            let p = progress.min(1.0);
            me.publish(
                |s| {
                    s.phase = phase;
                    s.progress = p;
                    if let Some(leg) = leg {
                        s.live_legs.push(leg);
                    }
                },
                on_change,
            );
        };

        // 1. Single-core.
        let single = workloads::cpu_mix(t * 4.0, &cancelled);
        if cancelled() {
            return None;
        }
        let single_cat = score::category("Single-core", single);
        step(
            self,
            Phase::MultiCore,
            Some(leg("single", "Single-core", single_cat.score)),
        );

        // 2. All cores: every core runs the mix concurrently; throughputs sum.
        let cores = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(2)
            .max(2);
        let per_core: Vec<Vec<WorkloadResult>> = std::thread::scope(|sc| {
            let handles: Vec<_> = (0..cores)
                .map(|_| sc.spawn(|| workloads::cpu_mix(t * 4.0, &cancelled)))
                .collect();
            handles.into_iter().filter_map(|h| h.join().ok()).collect()
        });
        if cancelled() {
            return None;
        }
        let summed = sum_by_id(&per_core);
        let multi: Vec<WorkloadResult> = summed
            .iter()
            .map(|r| WorkloadResult::new(&format!("multi.{}", &r.id[4..]), r.value, r.unit))
            .collect();
        let per_core_avg: Vec<WorkloadResult> = summed
            .iter()
            .map(|r| WorkloadResult::new(&r.id, r.value / cores as f64, r.unit))
            .collect();
        let multi_cat = CategoryScore {
            name: "All cores".into(),
            score: score::composite(&per_core_avg) * cores as f64,
            results: multi,
        };
        step(
            self,
            Phase::Memory,
            Some(leg("multi", "All cores", multi_cat.score)),
        );

        // 3. Memory.
        let mem = vec![
            workloads::memory_bandwidth(t, &cancelled),
            workloads::memory_latency(t, &cancelled),
        ];
        if cancelled() {
            return None;
        }
        let mem_cat = score::category("Memory", mem);
        step(self, Phase::Gpu, Some(leg("memory", "Memory", mem_cat.score)));

        // 4. GPU — may be unavailable; the category then drops out rather than zeroing.
        let gpu = self.gpu.as_ref().and_then(|g| g.matmul(t * 2.0, &cancelled));
        if cancelled() {
            return None;
        }
        let gpu_cat = gpu.map(|r| score::category("GPU", vec![r]));
        step(
            self,
            Phase::Neural,
            gpu_cat.as_ref().map(|c| leg("gpu", "GPU", c.score)),
        );

        // 5. Neural: the Mac's leg is Vision's feature print. No OS-shipped model exists on
        // Windows/Linux, so it drops out here, like it does on Macs without the ML stack.
        let neural_cat: Option<CategoryScore> = None;
        step(self, Phase::Sustained, None);

        // 6. Sustained (full profile).
        let mut throttle = None;
        let mut samples = Vec::new();
        if profile.sustained_seconds() > 0.0 {
            let bucket = 5.0;
            let buckets = (profile.sustained_seconds() / bucket) as usize;
            let mut bucket_scores: Vec<f64> = Vec::new();
            let start = Instant::now();
            for i in 0..buckets {
                if cancelled() {
                    break;
                }
                let all: Vec<Vec<WorkloadResult>> = std::thread::scope(|sc| {
                    let hs: Vec<_> = (0..cores)
                        .map(|_| sc.spawn(|| workloads::cpu_mix(bucket, &cancelled)))
                        .collect();
                    hs.into_iter().filter_map(|h| h.join().ok()).collect()
                });
                bucket_scores.push(score::composite(&sum_by_id(&all)));
                let sample = ThermalSample {
                    at_seconds: start.elapsed().as_secs_f64(),
                    temperature_c: self.thermal.temperature_c(),
                    fan_rpm: self.thermal.fan_rpm(),
                    thermal_state: self.thermal.thermal_state(),
                };
                samples.push(sample.clone());
                let first = bucket_scores[0];
                let rel = if first > 0.0 {
                    bucket_scores[bucket_scores.len() - 1] / first * 100.0
                } else {
                    100.0
                };
                let p = (progress + sustained_weight * (i + 1) as f64 / buckets as f64).min(1.0);
                self.publish(
                    |s| {
                        s.progress = p;
                        s.live_thermal = Some(sample);
                        let l = leg("sustained", "Sustained", rel);
                        match s.live_legs.iter_mut().find(|x| x.id == "sustained") {
                            Some(x) => *x = l,
                            None => s.live_legs.push(l),
                        }
                    },
                    on_change,
                );
            }
            if cancelled() {
                return None;
            }
            if let Some(&first) = bucket_scores.first().filter(|f| **f > 0.0) {
                let back_n = (bucket_scores.len() / 2).max(1);
                let back = &bucket_scores[bucket_scores.len() - back_n..];
                throttle = Some(back.iter().sum::<f64>() / back.len() as f64 / first);
            }
        }

        let composite = score::overall(&[
            Some(&single_cat),
            Some(&multi_cat),
            Some(&mem_cat),
            gpu_cat.as_ref(),
            None,
        ]);
        Some(BenchResult {
            date: crate::model::now_unix(),
            profile,
            single_core: single_cat,
            multi_core: multi_cat,
            memory: mem_cat,
            gpu: gpu_cat,
            neural: neural_cat,
            throttle_factor: throttle,
            thermal_samples: samples,
            composite,
            device_model: self.device_model.clone(),
            os_version: self.os_version.clone(),
        })
    }
}

fn leg(id: &'static str, name: &str, score: f64) -> LiveLeg {
    LiveLeg {
        id,
        name: t(name),
        score,
    }
}

fn sum_by_id(per_core: &[Vec<WorkloadResult>]) -> Vec<WorkloadResult> {
    let mut out: Vec<WorkloadResult> = Vec::new();
    for results in per_core {
        for r in results {
            match out.iter_mut().find(|o| o.id == r.id) {
                Some(o) => o.value += r.value,
                None => out.push(r.clone()),
            }
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    let _ = BenchUnit::MbPerSec;
    out
}

pub struct NullThermal;
impl ThermalSource for NullThermal {
    fn temperature_c(&self) -> Option<f64> {
        None
    }
    fn fan_rpm(&self) -> Option<f64> {
        None
    }
    fn thermal_state(&self) -> i32 {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeGpu;
    impl GpuCompute for FakeGpu {
        fn matmul(&self, _: f64, _: &(dyn Fn() -> bool + Sync)) -> Option<WorkloadResult> {
            Some(WorkloadResult::new("gpu.matmul", 2000.0, BenchUnit::Gflops))
        }
    }

    #[test]
    fn quick_profile_produces_a_result_and_history() {
        let dir = std::env::temp_dir().join(format!("blip-bench-test-{}", std::process::id()));
        let path = dir.join("bench.json");
        let e = BenchEngine::new(
            Arc::new(NullThermal),
            Some(Arc::new(FakeGpu)),
            "Test".into(),
            "OS".into(),
            Some(path.clone()),
        );
        let r = e.run_blocking(Profile::Quick).expect("result");
        assert!(r.composite > 0.0);
        assert_eq!(r.gpu.as_ref().map(|g| g.score.round()), Some(1000.0));
        assert!(r.neural.is_none());
        let again = BenchEngine::new(
            Arc::new(NullThermal),
            None,
            "Test".into(),
            "OS".into(),
            Some(path),
        );
        assert_eq!(again.state().history.len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }
}
