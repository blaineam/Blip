// soren.config.mjs — QA suites for Blip.
//
// Run locally:   node ../_shared/soren/soren.mjs run Blip
//                node ../_shared/soren/soren.mjs run Blip unit
//                node ../_shared/soren/soren.mjs doctor Blip
//
// Soren (🦉, the QA counterpart to Rocket) lives in _shared/soren and is pluggable
// per project via this file. See _shared/soren/docs/config.md for every field.
//
// Blip ships on: macOS direct download (Blip), Mac App Store (BlipAppStore, APPSTORE flag,
// sandboxed), Blip Helper (unsandboxed companion), iOS/iPadOS (BlipMobile) + its widgets,
// App Intents on both, and the blip.wemiller.com site (docs/). One suite per shipped surface.
//
// Blip.xcodeproj/project.pbxproj is gitignored — every Xcode suite sets `xcodegen: true` so a
// fresh checkout (or a tree with new files) regenerates it from project.yml first.
//
// `root` defaults to this file's directory (the Blip repo), so all paths below
// are relative to the repo root.
import { join } from 'node:path';

// Derived data for the UI suites: one fixed /tmp folder per suite (outside iCloud, so the
// repo never syncs build output; per suite, so the three runners never thrash each other).
// A reboot wipes /tmp, which costs one cold build — the price of the shared /tmp convention.
const DD = (suite) => join('/tmp', `soren-Blip-${suite}`);

export default {
  name: 'Blip',
  suites: {
    // ── The direct build's unit gate: BlipTests (XCTest), hosted by Blip.app on macOS.
    //    App Intents end-to-end against injected fakes, metric catalog, core models, Keep Awake
    //    (controller, extras host, lid-closed root loop via fakes), helper IPC security (router,
    //    TOTP windows, frame limits, real HelperClient over loopback), process kill against a
    //    child process, the real disk benchmark engine on a scratch dir, the MMDB GeoIP reader
    //    (incl. corrupt-file fuzzing) + gzip install path, the self-hosted speed test against a
    //    loopback HTTP server, traceroute parsing, SMART decoding, grades, formatting/share text.
    //    Shared/ code used by Blip Helper rides this suite (the helper has no test target).
    unit: {
      type: 'xcodebuild-test',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'Blip',
      destination: 'platform=macOS',
      xcodegen: true,
      description: 'BlipTests unit suite (Blip scheme, macOS, direct build)',
      tags: ['regression'],
    },

    // ── The same test bundle compiled as the Mac App Store variant (APPSTORE), so the
    //    `#if APPSTORE` branches — helper-gated Keep Awake extras, the sandbox's bookmark-only
    //    drive test, helper-version gating — actually execute under test. Own derived data so it
    //    never thrashes the `unit` build.
    'appstore-unit': {
      type: 'xcodebuild-test',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'Blip',
      destination: 'platform=macOS',
      xcodegen: true,
      extraArgs: ['SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG APPSTORE'],
      description: 'BlipTests compiled with APPSTORE (App Store code paths, macOS)',
      tags: ['regression'],
    },

    // ── Blip 2.0's iOS/iPadOS app + widget extension (the widgets build as an embedded
    //    dependency of the app scheme, so one suite gates both). MobileSmokeTests (real BenchKit
    //    quick run on the iOS runtime), feedback-wave tests, and MobileFeatureTests: disk speed
    //    test on a scratch folder, speed-test transfer engine against a loopback server,
    //    loopback ping/traceroute, the three Shortcuts intents, widget summary, share text — plus
    //    the cross-platform MMDB / grades / ICMP tests from BlipTests/CrossPlatform.
    mobile: {
      type: 'xcodebuild-test',
      platform: 'ios',
      project: 'Blip.xcodeproj',
      scheme: 'BlipMobile',
      destination: 'platform=iOS Simulator,name=iPhone 17 Pro',
      xcodegen: true,
      description: 'BlipMobile app + widgets (iOS simulator)',
      tags: ['regression'],
    },

    // ── UI tests (XCUITest), one suite per platform. The app runs with the DEBUG-only
    //    `-UITestMode` launch argument (Shared/UITestMode.swift): isolated defaults seeded with
    //    the screenshot fixtures, stubbed bench / speed / disk / ping / traceroute runners, no
    //    network, no helper, animations off. Own schemes (BlipUITests, BlipMobileUITests), so
    //    the CI path `xcodebuild test -scheme Blip` and the unit gates never pick them up.
    //
    //    macOS: BlipUITestHost ("Blip UITest", com.blainemiller.Blip.uitesthost) — the direct
    //    app's sources under their own bundle id, so the per-launch defaults wipe can never
    //    reach the real Blip's preferences. The XCUITest runner must be signed (ad-hoc is
    //    enough). It drives the real mouse and keyboard, so don't use the Mac while it runs.
    //    If it fails with "The test runner hung before establishing connection", the runner is
    //    sitting suspended at launch waiting for Developer Tools authorization (seen here with
    //    `DevToolsSecurity` disabled): approve the prompt, or once `sudo DevToolsSecurity -enable`.
    'ui-macos': {
      type: 'xcodebuild-test',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'BlipUITests',
      destination: 'platform=macOS',
      xcodegen: true,
      derivedDataPath: DD('ui-macos'),
      // Soren passes CODE_SIGNING_ALLOWED=NO; later settings win, and the macOS runner
      // must be signed to launch at all.
      extraArgs: ['CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-'],
      description: 'Blip menu-bar popover, inline detail panels, Settings and Traceroute window (XCUITest, -UITestMode, isolated bundle id)',
      tags: ['ui'],
    },
    // iOS + iPadOS: the same BlipMobileUITests bundle on both idioms (layout assertions branch
    // on the idiom). DEDICATED simulators (iOS 27.0), booted by the suite and shut down after it:
    // on the shared "iPhone 17 Pro" / "iPad Pro 13-inch (M5)" devices other projects' UI suites
    // launch their apps mid-run and steal the foreground (field-caught 2026-10-05: taps on Blip
    // landed while another app was frontmost). Create them once with
    //   xcrun simctl create "Blip UI iPhone 17 Pro" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0
    //   xcrun simctl create "Blip UI iPad Pro 13-inch (M5)" "iPad Pro 13-inch (M5)" com.apple.CoreSimulator.SimRuntime.iOS-27-0
    'ui-ios': {
      type: 'xcodebuild-test',
      platform: 'ios',
      project: 'Blip.xcodeproj',
      scheme: 'BlipMobileUITests',
      destination: 'platform=iOS Simulator,name=Blip UI iPhone 17 Pro,OS=27.0',
      shutdownSimulator: true,
      xcodegen: true,
      derivedDataPath: DD('ui-ios'),
      description: 'Blip iOS tabs, every detail screen, bench/speed/ping/trace flows, Settings, deep links (XCUITest, iPhone)',
      tags: ['ui'],
    },
    'ui-ipad': {
      type: 'xcodebuild-test',
      platform: 'ios',
      project: 'Blip.xcodeproj',
      scheme: 'BlipMobileUITests',
      destination: 'platform=iOS Simulator,name=Blip UI iPad Pro 13-inch (M5),OS=27.0',
      shutdownSimulator: true,
      xcodegen: true,
      derivedDataPath: DD('ui-ipad'),
      description: 'Blip iPadOS tabs, adaptive grid, detail screens and flows (XCUITest, iPad)',
      tags: ['ui'],
    },

    // ── The Mac App Store target itself (sandboxed entitlements, APPSTORE) must still compile;
    //    `appstore-unit` covers its logic, this catches target-only breakage before an upload.
    appstore: {
      type: 'xcodebuild-test',
      action: 'build',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'BlipAppStore',
      destination: 'platform=macOS',
      xcodegen: true,
      description: 'Mac App Store (sandboxed, APPSTORE) target builds',
    },

    // ── The unsandboxed helper. Its request router, process signalling, traceroute parsing
    //    and SMART decoding live in Shared/ and are tested by `unit`; this gates that the
    //    helper target (NWListener server, IOKit daemon) still compiles.
    helper: {
      type: 'xcodebuild-test',
      action: 'build',
      platform: 'macos',
      project: 'Blip.xcodeproj',
      scheme: 'BlipHelper',
      destination: 'platform=macOS',
      xcodegen: true,
      description: 'Blip Helper (privileged, unsandboxed) target builds',
    },

    // ── App-logic line-coverage ratchet over the hermetic unit suite (Scripts/coverage-check.sh;
    //    derived data under /tmp).
    coverage: {
      type: 'cmd',
      cmd: './Scripts/coverage-check.sh',
      description: 'App-logic coverage ratchet (BlipTests, macOS)',
      tags: ['regression'],
    },

    // ── Localization: every shipped catalog (Mac, iOS, widgets) translated into all 8
    //    languages with matching format specifiers, and CFBundleDevelopmentRegion = en in every
    //    Info.plist. Includes unit tests for the checker itself.
    l10n: {
      type: 'cmd',
      cmd: 'node',
      args: ['--test', 'Scripts/checks.test.mjs'],
      description: 'String catalogs complete + specifier-safe; dev region en; site i18n consistent',
      tags: ['regression'],
    },

    // ── blip.wemiller.com: the i18n runtime parses, and every page dictionary mirrors English,
    //    every data-i18n key exists, local references resolve, the screenshot manifest is whole.
    'web-syntax': {
      type: 'node-check',
      files: ['docs/i18n/i18n.js', 'Scripts/check-l10n.mjs', 'Scripts/check-site-i18n.mjs'],
      description: 'Site i18n runtime + gate scripts parse',
    },
    web: {
      type: 'cmd',
      cmd: 'node',
      args: ['Scripts/check-site-i18n.mjs'],
      description: 'Site dictionaries, keys, links and screenshot manifest consistent',
      tags: ['regression'],
    },
  },

  // Nothing here is a data-migration harness; `soren migrate Blip` falls back to
  // the regression-tagged suites, which are the right smoke test.
  migration: ['unit'],

  // All of these must be green before a release is cut.
  release: {
    requireGreen: ['unit', 'appstore-unit', 'mobile', 'appstore', 'helper', 'coverage', 'l10n', 'web-syntax', 'web'],
  },
};
