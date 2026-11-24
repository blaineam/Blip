//! `com.blainemiller.blip.core.Native` — one JNI export per bridge function. Strings in, strings
//! out; structured state is JSON. Nothing here keeps JNI references past the call.

use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jdouble, jint, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;

use crate::bridge;

fn arg(env: &mut JNIEnv, s: &JString) -> String {
    env.get_string(s).map(Into::into).unwrap_or_default()
}

fn ret(env: &mut JNIEnv, s: String) -> jstring {
    env.new_string(s)
        .map(|j| j.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

fn ret_opt(env: &mut JNIEnv, s: Option<String>) -> jstring {
    match s {
        Some(s) => ret(env, s),
        None => std::ptr::null_mut(),
    }
}

fn flag(b: bool) -> jboolean {
    if b {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_init(
    mut env: JNIEnv,
    _: JClass,
    data_dir: JString,
    language: JString,
    model: JString,
    os: JString,
) {
    let (d, l, m, o) = (
        arg(&mut env, &data_dir),
        arg(&mut env, &language),
        arg(&mut env, &model),
        arg(&mut env, &os),
    );
    bridge::init(&d, &l, &m, &o);
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_setThermal(
    _: JNIEnv,
    _: JClass,
    state: jint,
    temperature: jdouble,
) {
    bridge::set_thermal(state, temperature);
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_benchStart(
    _: JNIEnv,
    _: JClass,
    quick: jboolean,
) {
    bridge::bench_start(quick != JNI_FALSE);
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_benchCancel(_: JNIEnv, _: JClass) {
    bridge::bench_cancel();
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_benchState(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    let s = bridge::bench_state();
    ret(&mut env, s)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedStartSelfHosted(
    mut env: JNIEnv,
    _: JClass,
    base: JString,
) -> jstring {
    let b = arg(&mut env, &base);
    let e = bridge::speed_start_self_hosted(&b);
    ret_opt(&mut env, e)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedBeginExternal(
    _: JNIEnv,
    _: JClass,
) -> jboolean {
    flag(bridge::speed_begin_external())
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedExternalProgress(
    _: JNIEnv,
    _: JClass,
    upload: jboolean,
    mbps: jdouble,
) {
    bridge::speed_external_progress(upload != JNI_FALSE, mbps);
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedExternalComplete(
    _: JNIEnv,
    _: JClass,
    down: jdouble,
    up: jdouble,
) {
    bridge::speed_external_complete(down, up);
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedExternalFail(
    mut env: JNIEnv,
    _: JClass,
    message: JString,
) {
    let m = arg(&mut env, &message);
    bridge::speed_external_fail(&m);
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedExternalCancelled(
    _: JNIEnv,
    _: JClass,
) -> jboolean {
    flag(bridge::speed_external_cancelled())
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedCancel(_: JNIEnv, _: JClass) {
    bridge::speed_cancel();
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_speedState(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    let s = bridge::speed_state();
    ret(&mut env, s)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_diskStart(
    mut env: JNIEnv,
    _: JClass,
    dir: JString,
    size_mb: jint,
    label: JString,
) {
    let (d, l) = (arg(&mut env, &dir), arg(&mut env, &label));
    bridge::disk_start(&d, size_mb.max(0) as u32, &l);
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_diskCancel(_: JNIEnv, _: JClass) {
    bridge::disk_cancel();
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_diskState(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    let s = bridge::disk_state();
    ret(&mut env, s)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_ping(
    mut env: JNIEnv,
    _: JClass,
    host: JString,
) -> jdouble {
    let h = arg(&mut env, &host);
    bridge::ping(&h)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_traceStart(
    mut env: JNIEnv,
    _: JClass,
    host: JString,
) -> jstring {
    let h = arg(&mut env, &host);
    let e = bridge::trace_start(&h);
    ret_opt(&mut env, e)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_traceStop(_: JNIEnv, _: JClass) {
    bridge::trace_stop();
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_traceState(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    let s = bridge::trace_state();
    ret(&mut env, s)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_icmpAvailable(
    _: JNIEnv,
    _: JClass,
) -> jboolean {
    flag(bridge::icmp_available())
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_geoStatus(
    mut env: JNIEnv,
    _: JClass,
) -> jstring {
    let s = bridge::geo_status();
    ret(&mut env, s)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_geoDownload(_: JNIEnv, _: JClass) {
    bridge::geo_download();
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_geoRemove(_: JNIEnv, _: JClass) {
    bridge::geo_remove();
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_wanIp(mut env: JNIEnv, _: JClass) -> jstring {
    let ip = bridge::wan_ip();
    ret_opt(&mut env, ip)
}

#[no_mangle]
pub extern "system" fn Java_com_blainemiller_blip_core_Native_translate(
    mut env: JNIEnv,
    _: JClass,
    key: JString,
) -> jstring {
    let k = arg(&mut env, &key);
    let s = bridge::translate(&k);
    ret(&mut env, s)
}
