# Blip — App Store metadata

<!-- Pulled from App Store Connect. Edit, then: rocket meta Blip -->

## name
Blip Stats

## subtitle
Menu Bar Monitor

## description
Blip is a featherlight system monitor that lives in your menu bar. One click shows everything happening inside your Mac — CPU load, memory pressure, disk activity, network speeds, and more. No clutter, no subscriptions, no bloat. Just fast, accurate metrics when you need them.

Why people love Blip:

Your Mac is doing a lot behind the scenes. Blip makes all of it visible without getting in the way. It polls every two seconds, uses about 42 MB of memory, and weighs in at roughly 2 MB on disk. For comparison, most system monitors use 200+ MB and ship dozens of features you'll never touch.

What you get:

CPU — Total usage bar in your menu bar. Click to see per-core utilization, user/system/idle split, load averages, and P-core and E-core counts.
Memory — Usage percentage at a glance. Drill into total RAM, active/wired/compressed/app breakdown, swap usage, and memory pressure level.
Network — Live connectivity indicator in the menu bar. Tap to see upload/download speeds, total bandwidth since boot, all active interfaces listed with IPs, VPN detection for Tailscale and WireGuard, and a tap-to-reveal public IP. Bandwidth history chart with auto-scaled speed labels.
Disk — All mounted volumes with space used and free. Real-time read/write speeds, total data transferred since boot, and a live I/O history chart with auto-scaled Y-axis labels.*
GPU — Apple Silicon GPU utilization, renderer name, core count, and a historical usage chart.*
Battery — Charge level, health percentage, cycle count, temperature, time remaining, charging status, power source, and battery condition.*
Fans & Thermals — RPM per fan with min/max ranges, plus CPU and GPU temperatures read directly from the SMC. Shows "fanless Mac" gracefully on MacBook Air.*
Top Processes — See the top 5 processes by CPU and memory with app icons and accurate, delta-based measurements that match Activity Monitor.*
System — Mac model name, macOS version, uptime, thermal state, and Blip's own memory footprint so you can verify it stays tiny.
Some advanced metrics (disk I/O speeds, GPU utilization, battery health details, thermals, fan speeds, and top processes) require hardware-level access. Install the free Blip Helper companion app to unlock these features. Available at github.com/blaineam/blip.

Designed to stay out of your way:

Two menu bar layouts: horizontal (wide side-by-side) or stacked (compact vertical bars)
Hover any row to reveal a detailed sub-panel that updates in real-time
Customizable colors: category colors, monochrome to match your menu bar, or pick your own
Separate toggles for measurement labels and value labels
Optional utilization colorization at high usage levels
Launch at login with one toggle
Built right:

Blip is written in Swift with strict concurrency, async/await throughout, and zero external dependencies. It targets Apple Silicon natively. Every release is notarized by Apple.

If you've been looking for a system monitor that's fast, accurate, beautiful, and respectful of your Mac's resources, Blip is it.

## keywords
system monitor,cpu usage,memory pressure,menu bar,activity monitor,gpu,battery health,fan speed,mac

## promotional_text
See your Mac's vitals at a glance. CPU, memory, disk, GPU, network, battery, fans, and thermals — all live in your menu bar. Tiny footprint. Zero dependencies.

## whats_new
+ Adds speed tests for both internal and external disks as well as network speed tests too!
+ Adds Traceroute feature with support for mapped routes to help you test and monitor spotty networks
+ Adds recommended actions to keep your machine running smoothly that can be dismissed if desired. 
* Fixes issue with total data transferred over the network being inaccurate

## marketing_url
https://wemiller.com/apps/blip/

## support_url
https://wemiller.com

## privacy_policy_url
https://wemiller.com/privacy
