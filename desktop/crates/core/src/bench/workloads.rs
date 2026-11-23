//! BenchKit workloads, ported from `Shared/BenchKit/BenchWorkloads.swift`. Each runs for a time
//! budget and reports throughput, so results compare across devices. The workloads are the same
//! shapes, sizes and inputs as the Mac; the libraries differ (pure-Rust SHA-256 / LZFSE / FFT
//! instead of CryptoKit / Compression / vDSP), so cross-platform scores are close, not identical.

use std::time::Instant;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BenchUnit {
    #[serde(rename = "MB/s")]
    MbPerSec,
    #[serde(rename = "GB/s")]
    GbPerSec,
    #[serde(rename = "kFFT/s")]
    FftPerSec,
    #[serde(rename = "ns")]
    NsPerAccess,
    #[serde(rename = "GFLOPS")]
    Gflops,
    #[serde(rename = "ops/s")]
    OpsPerSec,
}

impl BenchUnit {
    pub fn label(self) -> &'static str {
        match self {
            BenchUnit::MbPerSec => "MB/s",
            BenchUnit::GbPerSec => "GB/s",
            BenchUnit::FftPerSec => "kFFT/s",
            BenchUnit::NsPerAccess => "ns",
            BenchUnit::Gflops => "GFLOPS",
            BenchUnit::OpsPerSec => "ops/s",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkloadResult {
    pub id: String,
    pub value: f64,
    pub unit: BenchUnit,
}

impl WorkloadResult {
    pub fn new(id: &str, value: f64, unit: BenchUnit) -> Self {
        Self { id: id.into(), value, unit }
    }
}

pub type Cancelled<'a> = &'a (dyn Fn() -> bool + Sync);

fn mb_per_sec(bytes: usize, seconds: f64) -> f64 {
    bytes as f64 / seconds.max(0.001) / 1_000_000.0
}

pub fn sha256(seconds: f64, cancelled: Cancelled) -> WorkloadResult {
    let chunk = make_buffer(8 << 20, Pattern::Pseudorandom);
    let mut hashed = 0usize;
    let deadline = Instant::now() + std::time::Duration::from_secs_f64(seconds);
    let mut h = Sha256::new();
    while Instant::now() < deadline && !cancelled() {
        h.update(&chunk);
        hashed += chunk.len();
    }
    std::hint::black_box(h.finalize());
    WorkloadResult::new("cpu.sha256", mb_per_sec(hashed, seconds), BenchUnit::MbPerSec)
}

pub fn compress_lzfse(seconds: f64, cancelled: Cancelled) -> WorkloadResult {
    let src = make_buffer(8 << 20, Pattern::HalfCompressible);
    let mut dst: Vec<u8> = Vec::with_capacity(src.len() + (src.len() >> 2));
    let mut processed = 0usize;
    let deadline = Instant::now() + std::time::Duration::from_secs_f64(seconds);
    while Instant::now() < deadline && !cancelled() {
        dst.clear();
        if lzfse_rust::encode_bytes(&src, &mut dst).is_err() {
            break;
        }
        processed += src.len();
    }
    std::hint::black_box(&dst);
    WorkloadResult::new("cpu.lzfse", mb_per_sec(processed, seconds), BenchUnit::MbPerSec)
}

#[derive(Serialize, Deserialize)]
struct Record {
    id: i64,
    name: String,
    score: f64,
    tags: Vec<String>,
    active: bool,
}

pub fn json_decode(seconds: f64, cancelled: Cancelled) -> WorkloadResult {
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    let records: Vec<Record> = (0..4000)
        .map(|i| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            Record {
                id: i,
                name: format!("record-{i}-{:08X}", state as u32),
                score: i as f64 * 1.5,
                tags: vec!["alpha".into(), "bravo".into(), format!("tag{}", i % 17)],
                active: i % 3 == 0,
            }
        })
        .collect();
    let blob = serde_json::to_vec(&records).expect("records encode");
    let mut processed = 0usize;
    let deadline = Instant::now() + std::time::Duration::from_secs_f64(seconds);
    while Instant::now() < deadline && !cancelled() {
        let decoded: Vec<Record> = serde_json::from_slice(&blob).expect("records decode");
        std::hint::black_box(decoded);
        processed += blob.len();
    }
    WorkloadResult::new("cpu.json", mb_per_sec(processed, seconds), BenchUnit::MbPerSec)
}

/// 1024-point real FFTs, done the way vDSP's `fft_zrip` does them: a 512-point complex FFT of
/// the packed signal plus the real-split post-processing pass.
pub fn fft(seconds: f64, cancelled: Cancelled) -> WorkloadResult {
    use rustfft::num_complex::Complex32;
    let n = 1024usize;
    let half = n / 2;
    let plan = rustfft::FftPlanner::<f32>::new().plan_fft_forward(half);
    let input: Vec<Complex32> =
        (0..half).map(|i| Complex32::new((i as f64 * 0.37).sin() as f32, 0.0)).collect();
    let mut buf = input.clone();
    let mut scratch = vec![Complex32::default(); plan.get_inplace_scratch_len()];
    let twiddles: Vec<Complex32> = (0..half)
        .map(|k| {
            let a = -std::f32::consts::PI * k as f32 / half as f32;
            Complex32::new(a.cos(), a.sin())
        })
        .collect();
    let mut count = 0u64;
    let deadline = Instant::now() + std::time::Duration::from_secs_f64(seconds);
    while Instant::now() < deadline && !cancelled() {
        for _ in 0..256 {
            plan.process_with_scratch(&mut buf, &mut scratch);
            // Real-split post-processing (what turns the half-size complex FFT into a real one).
            for k in 1..half / 2 {
                let a = buf[k];
                let b = buf[half - k].conj();
                let e = (a + b) * 0.5;
                let o = (a - b) * Complex32::new(0.0, -0.5) * twiddles[k];
                buf[k] = e + o;
                buf[half - k] = (e - o).conj();
            }
            // Keep values bounded so repeated in-place transforms don't overflow to inf.
            buf[0] = input[0];
            let s = 1.0 / half as f32;
            for v in buf.iter_mut() {
                *v *= s;
            }
        }
        count += 256;
    }
    std::hint::black_box(&buf);
    WorkloadResult::new("cpu.fft", count as f64 / seconds / 1000.0, BenchUnit::FftPerSec)
}

pub fn cpu_mix(seconds: f64, cancelled: Cancelled) -> Vec<WorkloadResult> {
    let slice = seconds / 4.0;
    vec![
        sha256(slice, cancelled),
        compress_lzfse(slice, cancelled),
        json_decode(slice, cancelled),
        fft(slice, cancelled),
    ]
}

/// Streaming triad y = a·x + y over 32 MB arrays; GB/s of traffic actually moved.
pub fn memory_bandwidth(seconds: f64, cancelled: Cancelled) -> WorkloadResult {
    let count = (32 << 20) / std::mem::size_of::<f32>();
    let x = vec![1.25f32; count];
    let y = vec![0.5f32; count];
    let mut out = vec![0f32; count];
    let a = std::hint::black_box(1.0001f32);
    let mut bytes = 0usize;
    let deadline = Instant::now() + std::time::Duration::from_secs_f64(seconds);
    while Instant::now() < deadline && !cancelled() {
        for ((o, xv), yv) in out.iter_mut().zip(&x).zip(&y) {
            *o = xv * a + yv;
        }
        std::hint::black_box(&mut out);
        bytes += count * std::mem::size_of::<f32>() * 3;
    }
    WorkloadResult::new("mem.bandwidth", bytes as f64 / seconds / 1e9, BenchUnit::GbPerSec)
}

/// Dependent-load latency around a shuffled 64 MB ring (Sattolo: one full cycle).
pub fn memory_latency(seconds: f64, cancelled: Cancelled) -> WorkloadResult {
    let count = 8usize << 20;
    let mut ring: Vec<usize> = (0..count).collect();
    let mut rng: u64 = 0x2545_F491_4F6C_DD1D ^ std::process::id() as u64;
    for i in (1..count).rev() {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        let j = (rng % i as u64) as usize;
        ring.swap(i, j);
    }
    let mut idx = 0usize;
    let mut hops = 0u64;
    let start = Instant::now();
    let deadline = start + std::time::Duration::from_secs_f64(seconds);
    while Instant::now() < deadline && !cancelled() {
        for _ in 0..(64 << 10) {
            idx = ring[idx];
        }
        hops += 64 << 10;
    }
    let ns = start.elapsed().as_secs_f64() * 1e9 / hops.max(1) as f64;
    std::hint::black_box(idx);
    WorkloadResult::new("mem.latency", ns, BenchUnit::NsPerAccess)
}

#[derive(Clone, Copy)]
enum Pattern {
    Pseudorandom,
    HalfCompressible,
}

fn make_buffer(bytes: usize, pattern: Pattern) -> Vec<u8> {
    let words = bytes / 8;
    let mut out = Vec::with_capacity(bytes);
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    for i in 0..words {
        let v = match pattern {
            Pattern::HalfCompressible if (i >> 6) & 1 == 0 => 0x2020_2020_2020_2020,
            _ => {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state
            }
        };
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workloads_produce_throughput() {
        let never = || false;
        for r in cpu_mix(0.2, &never) {
            assert!(r.value > 0.0, "{} measured nothing", r.id);
        }
        assert!(memory_bandwidth(0.05, &never).value > 0.0);
    }

    #[test]
    fn cancellation_stops_immediately() {
        let always = || true;
        assert_eq!(sha256(5.0, &always).value, 0.0);
    }

    #[test]
    fn lzfse_round_trips_the_bench_input() {
        let src = make_buffer(1 << 16, Pattern::HalfCompressible);
        let mut enc = Vec::new();
        lzfse_rust::encode_bytes(&src, &mut enc).unwrap();
        assert!(enc.len() < src.len());
        let mut dec = Vec::new();
        lzfse_rust::decode_bytes(&enc, &mut dec).unwrap();
        assert_eq!(dec, src);
    }
}
