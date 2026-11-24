//! Blip Bench's GPU leg on Linux: the Windows leg's 1024³ single-precision matrix multiply
//! (register-blocked 64×64 tiles, 16×16 threads each computing 4×4) as a WGSL compute shader on
//! wgpu — Vulkan on Mesa (RADV, ANV, NVK, V3DV on the Raspberry Pi 4/5) and NVIDIA, or GLES 3.1.
//! Same N and the same 2·N³ FLOP count as the Mac's MPS GEMM and the Windows D3D11 kernel.

use std::time::Instant;

use blip_core::bench::{BenchUnit, GpuCompute, WorkloadResult};
use wgpu::util::DeviceExt;

const N: u32 = 1024;

const SHADER: &str = r#"
const N: u32 = 1024u;
const BM: u32 = 64u;
const BK: u32 = 16u;
@group(0) @binding(0) var<storage, read> A: array<f32>;
@group(0) @binding(1) var<storage, read> B: array<f32>;
@group(0) @binding(2) var<storage, read_write> C: array<f32>;
var<workgroup> As: array<array<f32, 64>, 16>;
var<workgroup> Bs: array<array<f32, 64>, 16>;

@compute @workgroup_size(16, 16, 1)
fn main(@builtin(workgroup_id) g: vec3<u32>,
        @builtin(local_invocation_id) t: vec3<u32>,
        @builtin(local_invocation_index) li: u32) {
    let rowBase = g.y * BM;
    let colBase = g.x * BM;
    var acc: array<array<f32, 4>, 4>;
    for (var k0 = 0u; k0 < N; k0 += BK) {
        for (var l = 0u; l < 4u; l++) {
            let idx = li + l * 256u;
            let ar = idx / BK;
            let ac = idx % BK;
            As[ac][ar] = A[(rowBase + ar) * N + k0 + ac];
            let br = idx / BM;
            let bc = idx % BM;
            Bs[br][bc] = B[(k0 + br) * N + colBase + bc];
        }
        workgroupBarrier();
        for (var k = 0u; k < BK; k++) {
            var a: array<f32, 4>;
            var b: array<f32, 4>;
            for (var q = 0u; q < 4u; q++) {
                a[q] = As[k][t.y * 4u + q];
                b[q] = Bs[k][t.x * 4u + q];
            }
            for (var i = 0u; i < 4u; i++) {
                for (var j = 0u; j < 4u; j++) {
                    acc[i][j] += a[i] * b[j];
                }
            }
        }
        workgroupBarrier();
    }
    for (var i = 0u; i < 4u; i++) {
        for (var j = 0u; j < 4u; j++) {
            C[(rowBase + t.y * 4u + i) * N + colBase + t.x * 4u + j] = acc[i][j];
        }
    }
}
"#;

pub struct WgpuCompute;

struct Rig {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::ComputePipeline,
    bind: wgpu::BindGroup,
}

fn setup() -> Option<Rig> {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN | wgpu::Backends::GL,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .ok()?;
    // llvmpipe / lavapipe would "benchmark" the CPU.
    if adapter.get_info().device_type == wgpu::DeviceType::Cpu {
        return None;
    }
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("blip-bench"),
        required_limits: adapter.limits(),
        ..Default::default()
    }))
    .ok()?;
    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("gemm"),
        source: wgpu::ShaderSource::Wgsl(SHADER.into()),
    });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("gemm"),
        layout: None,
        module: &module,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });
    let n2 = (N * N) as usize;
    let a: Vec<f32> = (0..n2).map(|i| (i % 97) as f32 * 0.013).collect();
    let b: Vec<f32> = (0..n2).map(|i| (i % 89) as f32 * 0.011).collect();
    let bytes = |v: &[f32]| v.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>();
    let ba = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("A"),
        contents: &bytes(&a),
        usage: wgpu::BufferUsages::STORAGE,
    });
    let bb = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("B"),
        contents: &bytes(&b),
        usage: wgpu::BufferUsages::STORAGE,
    });
    let bc = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("C"),
        size: (n2 * 4) as u64,
        usage: wgpu::BufferUsages::STORAGE,
        mapped_at_creation: false,
    });
    let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("gemm"),
        layout: &pipeline.get_bind_group_layout(0),
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: ba.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: bb.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: bc.as_entire_binding(),
            },
        ],
    });
    Some(Rig {
        device,
        queue,
        pipeline,
        bind,
    })
}

fn run(rig: &Rig, multiplies: u32) -> Option<()> {
    let groups = N / 64;
    let mut enc = rig.device.create_command_encoder(&Default::default());
    {
        let mut pass = enc.begin_compute_pass(&Default::default());
        pass.set_pipeline(&rig.pipeline);
        pass.set_bind_group(0, &rig.bind, &[]);
        for _ in 0..multiplies {
            pass.dispatch_workgroups(groups, groups, 1);
        }
    }
    rig.queue.submit([enc.finish()]);
    rig.device
        .poll(wgpu::PollType::wait_indefinitely())
        .ok()
        .map(|_| ())
}

impl GpuCompute for WgpuCompute {
    fn matmul(&self, seconds: f64, cancelled: &(dyn Fn() -> bool + Sync)) -> Option<WorkloadResult> {
        let rig = setup()?;
        // Warm-up (shader compile, first dispatch). Over two seconds for one multiply means a
        // software path: drop the leg rather than score it.
        let warm = Instant::now();
        run(&rig, 1)?;
        if warm.elapsed().as_secs_f64() > 2.0 {
            return None;
        }
        let mut multiplies = 0u64;
        let start = Instant::now();
        while start.elapsed().as_secs_f64() < seconds && !cancelled() {
            run(&rig, 4)?;
            multiplies += 4;
        }
        let elapsed = start.elapsed().as_secs_f64();
        if multiplies == 0 || elapsed <= 0.0 {
            return None;
        }
        let flops = 2.0 * (N as f64).powi(3) * multiplies as f64;
        Some(WorkloadResult::new(
            "gpu.matmul",
            flops / elapsed / 1e9,
            BenchUnit::Gflops,
        ))
    }
}
