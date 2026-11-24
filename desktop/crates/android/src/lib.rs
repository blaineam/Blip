//! Blip for Android's native core. The Kotlin app reads device stats from Android's own APIs;
//! everything that has to match the Mac, iPhone, Windows and Linux exactly comes from here:
//! Blip Bench (same workloads and frozen reference units, GPU leg on Vulkan), the OpenSpeedTest
//! tester (self-hosted natively; the public widget's numbers are fed in from a WebView), the
//! uncached disk test, ping and traceroute/MTR over unprivileged ICMP ping sockets (Android
//! allows them for apps), offline GeoIP, and the WAN address lookup.
//!
//! The bridge is deliberately thin: plain functions in [`bridge`] that take and return strings
//! (JSON for structured state), wrapped one-to-one as JNI exports of
//! `com.blainemiller.blip.core.Native`. Kotlin polls the `*State` calls while a test runs.

pub mod bridge;
mod jni_exports;
