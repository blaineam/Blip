// soren.config.mjs — QA suites for Blip.
//
// Run locally:   node ../_shared/soren/soren.mjs run Blip
//                node ../_shared/soren/soren.mjs run Blip unit
//                node ../_shared/soren/soren.mjs doctor Blip
//
// Soren (🦉, the QA counterpart to Rocket) lives in _shared/soren and is pluggable
// per project via this file. See _shared/soren/docs/config.md for every field.
//
// Blip is a macOS-only menu-bar system monitor. `xcodebuild -list` reports three
// schemes — Blip, BlipAppStore, BlipHelper — matching the four xcodegen targets
// (Blip, BlipTests, BlipAppStore, BlipHelper) in project.yml. Only the `Blip`
// scheme has a test action; it runs the BlipTests unit bundle hosted by Blip.app.
//
// `root` defaults to this file's directory (the Blip repo), so all paths below
// are relative to the repo root.
export default {
  name: 'Blip',
  suites: {
    // ── The real unit gate: BlipTests (XCTest), hosted by Blip.app on macOS.
    //    Covers the App Intents surface end-to-end against injected fakes
    //    (MetricIntentTests, SettingIntentTests, SpeedTestIntentTests,
    //    TracerouteIntentTests) plus the metric catalog and core models.
    //    macOS destination — no simulator to boot.
    unit: {
      type: 'xcodebuild-test',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'Blip',
      destination: 'platform=macOS',
      description: 'BlipTests unit suite (Blip scheme, macOS)',
      tags: ['regression'],
    },

    // ── Blip 2.0's iOS/iPadOS app + widget extension (the widgets build as an embedded
    //    dependency of the app scheme, so one suite gates both). Runs MobileSmokeTests on a
    //    simulator — including a REAL BenchKit quick run on the iOS runtime, which is the
    //    cross-platform promise ("one score scale, Mac and iPhone") actually being exercised.
    mobile: {
      type: 'xcodebuild-test',
      platform: 'ios',
      project: 'Blip.xcodeproj',
      scheme: 'BlipMobile',
      destination: 'platform=iOS Simulator,name=iPhone 17 Pro',
      description: 'BlipMobile app + widgets (iOS simulator, MobileSmokeTests)',
      tags: ['regression'],
    },

    // ── The Mac App Store variant is a SEPARATE target compiled with
    //    SWIFT_ACTIVE_COMPILATION_CONDITIONS=APPSTORE and the sandboxed
    //    entitlements file. It shares Blip/Sources but the `#if APPSTORE`
    //    branches are NOT exercised by the `Blip` scheme's tests, so a compile
    //    gate is the honest thing to assert here: it has no test action of its
    //    own. This catches APPSTORE-only build breakage before an upload does.
    appstore: {
      type: 'xcodebuild-test',
      action: 'build',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'BlipAppStore',
      destination: 'platform=macOS',
      description: 'Mac App Store (sandboxed, APPSTORE) target builds',
    },

    // ── The unsandboxed privileged helper (localhost TCP + TOTP, process kill,
    //    traceroute, SMART). No test target exists for it — the protocol types
    //    it shares with the app live in Shared/ and ride the `unit` suite — so
    //    the meaningful gate is that it still compiles. Same build-only pattern
    //    Haven uses for its HavenMac scheme.
    helper: {
      type: 'xcodebuild-test',
      action: 'build',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'BlipHelper',
      destination: 'platform=macOS',
      description: 'Blip Helper (privileged, unsandboxed) target builds',
    },
  },

  // Nothing here is a data-migration harness; `soren migrate Blip` falls back to
  // the regression-tagged suite (unit), which is the right smoke test.
  migration: ['unit'],

  // All three must be green before a release is cut.
  release: { requireGreen: ['unit', 'appstore', 'helper'] },
};
