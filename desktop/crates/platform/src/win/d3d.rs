//! Blip Bench's GPU leg on Windows: 1024³ single-precision matrix multiply as a Direct3D 11
//! compute shader (register-blocked 64×64 tiles), the same N and the same 2·N³ FLOP count as
//! the Mac's MPS GEMM. D3D11 runs on every GPU Windows 10/11 supports, ARM64 included, and the
//! shader compiler (d3dcompiler_47) ships with the OS — nothing bundled, nothing elevated.

use std::time::Instant;

use blip_core::bench::{BenchUnit, GpuCompute, WorkloadResult};
use windows::core::{s, Interface};
use windows::Win32::Foundation::HMODULE;
use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_UNKNOWN;

const N: u32 = 1024;

const SHADER: &str = r#"
#define N 1024
#define BM 64
#define BK 16
StructuredBuffer<float> A : register(t0);
StructuredBuffer<float> B : register(t1);
RWStructuredBuffer<float> C : register(u0);
groupshared float As[BK][BM];
groupshared float Bs[BK][BM];
[numthreads(16, 16, 1)]
void main(uint3 g : SV_GroupID, uint3 t : SV_GroupThreadID, uint li : SV_GroupIndex) {
    uint rowBase = g.y * BM;
    uint colBase = g.x * BM;
    float acc[4][4];
    [unroll] for (uint i = 0; i < 4; i++) { [unroll] for (uint j = 0; j < 4; j++) { acc[i][j] = 0; } }
    for (uint k0 = 0; k0 < N; k0 += BK) {
        [unroll] for (uint l = 0; l < 4; l++) {
            uint idx = li + l * 256;
            uint ar = idx / BK, ac = idx % BK;
            As[ac][ar] = A[(rowBase + ar) * N + k0 + ac];
            uint br = idx / BM, bc = idx % BM;
            Bs[br][bc] = B[(k0 + br) * N + colBase + bc];
        }
        GroupMemoryBarrierWithGroupSync();
        [unroll] for (uint k = 0; k < BK; k++) {
            float a[4], b[4];
            [unroll] for (uint q = 0; q < 4; q++) { a[q] = As[k][t.y * 4 + q]; b[q] = Bs[k][t.x * 4 + q]; }
            [unroll] for (uint i2 = 0; i2 < 4; i2++) { [unroll] for (uint j2 = 0; j2 < 4; j2++) { acc[i2][j2] += a[i2] * b[j2]; } }
        }
        GroupMemoryBarrierWithGroupSync();
    }
    [unroll] for (uint i3 = 0; i3 < 4; i3++) {
        [unroll] for (uint j3 = 0; j3 < 4; j3++) {
            C[(rowBase + t.y * 4 + i3) * N + colBase + t.x * 4 + j3] = acc[i3][j3];
        }
    }
}
"#;

pub struct D3DCompute;

impl D3DCompute {
    pub fn new() -> Option<Self> {
        Some(Self)
    }
}

struct Rig {
    ctx: ID3D11DeviceContext,
    device: ID3D11Device,
    _bufs: Vec<ID3D11Buffer>,
}

fn setup() -> windows::core::Result<Rig> {
    let mut device = None;
    let mut ctx = None;
    // SAFETY: standard device creation with out-params.
    unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_FLAG(0),
            Some(&[D3D_FEATURE_LEVEL_11_0]),
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut ctx),
        )?;
    }
    let device = device.ok_or_else(windows::core::Error::empty)?;
    let ctx = ctx.ok_or_else(windows::core::Error::empty)?;

    let mut code = None;
    let mut errors = None;
    // SAFETY: source buffer + NUL-free length; out-params.
    unsafe {
        D3DCompile(SHADER.as_ptr() as _, SHADER.len(), s!("blipbench"), None, None, s!("main"), s!("cs_5_0"), 1 << 15, 0, &mut code, Some(&mut errors))?;
    }
    let code = code.ok_or_else(windows::core::Error::empty)?;
    // SAFETY: blob pointer/size from D3DCompile.
    let bytes = unsafe { std::slice::from_raw_parts(code.GetBufferPointer() as *const u8, code.GetBufferSize()) };
    let mut cs = None;
    unsafe { device.CreateComputeShader(bytes, None, Some(&mut cs))? };
    let cs = cs.ok_or_else(windows::core::Error::empty)?;

    let n2 = (N * N) as usize;
    let a: Vec<f32> = (0..n2).map(|i| (i % 97) as f32 * 0.013).collect();
    let b: Vec<f32> = (0..n2).map(|i| (i % 89) as f32 * 0.011).collect();
    let make = |data: Option<&[f32]>, uav: bool| -> windows::core::Result<ID3D11Buffer> {
        let desc = D3D11_BUFFER_DESC {
            ByteWidth: (n2 * 4) as u32,
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: if uav { D3D11_BIND_UNORDERED_ACCESS.0 as u32 } else { D3D11_BIND_SHADER_RESOURCE.0 as u32 },
            CPUAccessFlags: 0,
            MiscFlags: D3D11_RESOURCE_MISC_BUFFER_STRUCTURED.0 as u32,
            StructureByteStride: 4,
        };
        let init = data.map(|d| D3D11_SUBRESOURCE_DATA { pSysMem: d.as_ptr() as _, ..Default::default() });
        let mut buf = None;
        // SAFETY: desc/init valid for the call.
        unsafe { device.CreateBuffer(&desc, init.as_ref().map(|i| i as *const _), Some(&mut buf))? };
        buf.ok_or_else(windows::core::Error::empty)
    };
    let ba = make(Some(&a), false)?;
    let bb = make(Some(&b), false)?;
    let bc = make(None, true)?;

    let srv_desc = D3D11_SHADER_RESOURCE_VIEW_DESC {
        Format: DXGI_FORMAT_UNKNOWN,
        ViewDimension: D3D_SRV_DIMENSION_BUFFER,
        Anonymous: D3D11_SHADER_RESOURCE_VIEW_DESC_0 {
            Buffer: D3D11_BUFFER_SRV { Anonymous1: D3D11_BUFFER_SRV_0 { FirstElement: 0 }, Anonymous2: D3D11_BUFFER_SRV_1 { NumElements: n2 as u32 } },
        },
    };
    let mut srv_a = None;
    let mut srv_b = None;
    let mut uav = None;
    let uav_desc = D3D11_UNORDERED_ACCESS_VIEW_DESC {
        Format: DXGI_FORMAT_UNKNOWN,
        ViewDimension: D3D11_UAV_DIMENSION_BUFFER,
        Anonymous: D3D11_UNORDERED_ACCESS_VIEW_DESC_0 { Buffer: D3D11_BUFFER_UAV { FirstElement: 0, NumElements: n2 as u32, Flags: 0 } },
    };
    // SAFETY: views over our own buffers.
    unsafe {
        device.CreateShaderResourceView(&ba, Some(&srv_desc), Some(&mut srv_a))?;
        device.CreateShaderResourceView(&bb, Some(&srv_desc), Some(&mut srv_b))?;
        device.CreateUnorderedAccessView(&bc, Some(&uav_desc), Some(&mut uav))?;
        ctx.CSSetShader(&cs, None);
        ctx.CSSetShaderResources(0, Some(&[srv_a, srv_b]));
        ctx.CSSetUnorderedAccessViews(0, 1, Some(&uav), None);
    }
    Ok(Rig { ctx, device, _bufs: vec![ba, bb, bc] })
}

fn wait_idle(rig: &Rig) -> windows::core::Result<()> {
    let desc = D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 };
    let mut q = None;
    // SAFETY: event query on our device.
    unsafe { rig.device.CreateQuery(&desc, Some(&mut q))? };
    let q = q.ok_or_else(windows::core::Error::empty)?;
    let asyncq: ID3D11Asynchronous = q.cast()?;
    unsafe {
        rig.ctx.End(&asyncq);
        rig.ctx.Flush();
    }
    let start = Instant::now();
    loop {
        let mut done: i32 = 0;
        // SAFETY: event queries return a BOOL.
        let _ = unsafe { rig.ctx.GetData(&asyncq, Some(&mut done as *mut i32 as _), 4, 0) };
        if done != 0 || start.elapsed().as_secs() > 20 {
            return Ok(());
        }
        std::thread::yield_now();
    }
}

impl GpuCompute for D3DCompute {
    fn matmul(&self, seconds: f64, cancelled: &(dyn Fn() -> bool + Sync)) -> Option<WorkloadResult> {
        let rig = setup().ok()?;
        let groups = N / 64;
        // Warm-up: pipeline creation / first dispatch isn't throughput.
        unsafe { rig.ctx.Dispatch(groups, groups, 1) };
        wait_idle(&rig).ok()?;
        let mut multiplies = 0u64;
        let start = Instant::now();
        while start.elapsed().as_secs_f64() < seconds && !cancelled() {
            for _ in 0..4 {
                unsafe { rig.ctx.Dispatch(groups, groups, 1) };
            }
            wait_idle(&rig).ok()?;
            multiplies += 4;
        }
        let elapsed = start.elapsed().as_secs_f64();
        if multiplies == 0 || elapsed <= 0.0 {
            return None;
        }
        let flops = 2.0 * (N as f64).powi(3) * multiplies as f64;
        Some(WorkloadResult::new("gpu.matmul", flops / elapsed / 1e9, BenchUnit::Gflops))
    }
}
