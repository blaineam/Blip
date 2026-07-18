// Knox 🦊 audit config for Blip — a macOS menu-bar system monitor (CPU/GPU/
// memory/disk/battery/thermals/network) with S.M.A.R.T. drive health, disk and
// network speed tests, traceroute/MTR, and a Shortcuts (App Intents) surface.
// Resolved by `knox audit Blip`. Lives WITH the repo so the audit surface
// travels with the code.
//
// Blip ships in two shapes from one source tree:
//   • the DIRECT build (Blip target)      — unsandboxed, Developer ID, notarized
//   • the MAS build   (BlipAppStore)      — sandboxed, `#if APPSTORE` branches
// plus BlipHelper, a SEPARATE unsandboxed helper app the sandboxed build talks
// to over localhost TCP for the things the sandbox forbids. That helper is where
// the privilege lives, and it is the centre of gravity for this audit.

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Knox reads `contextDocs` entries against the CWD it happens to be launched
// from, not against `root` — so resolve them here and hand it absolute paths.
const HERE = dirname(fileURLToPath(import.meta.url));
const doc = (p) => join(HERE, p);

export default {
  project: 'Blip',
  root: '.',

  scope: [
    // ── The privilege boundary: an unsandboxed helper that accepts commands
    //    over a loopback TCP socket and will kill arbitrary PIDs on request.
    'BlipHelper/Sources',
    'Shared/HelperProtocol.swift',       // the wire format both sides parse
    'Shared/TOTP.swift',                 // the ONLY thing authenticating that socket
    'Blip/Sources/Shared/HelperClient.swift',

    // ── The automation surface: App Intents are invocable by any Shortcut, any
    //    other app's shortcut, and by automations the user never reviews.
    'Blip/Sources/Intents',

    // ── Subprocess + raw-device access.
    'Blip/Sources/Services/DiskMonitor.swift',    // diskutil subprocess + IONVMe/ATA SMART user clients
    'Blip/Sources/Services/ProcessMonitor.swift', // /bin/ps
    'Blip/Sources/Services/SystemMonitor.swift',  // system_profiler, traceroute orchestration, kill
    'Blip/Sources/Services/SMCKit.swift',         // AppleSMC user client
    'Blip/Sources/Models/HostValidation.swift',   // the allowlist that keeps hosts out of argv

    // ── Network-facing code: speed tests and the GeoIP database download.
    'Blip/Sources/Services/NetworkMonitor.swift',
    'Blip/Sources/Services/OpenSpeedTestWidgetRunner.swift',
    'Blip/Sources/Services/GeoIPDatabase.swift',
    'Blip/Sources/Services/MMDB.swift',           // parser for a downloaded binary blob

    // ── Entitlements: what each shape of the app is actually allowed to do.
    'Blip/Resources/Blip.entitlements',
    'Blip/Resources/BlipAppStore.entitlements',
    'BlipHelper/Resources/BlipHelper.entitlements',
  ],

  focusAreas: [
    'authn',            // the TOTP handshake on the helper socket
    'authz',            // who may ask the helper to kill a process
    'input-validation', // hostnames → traceroute argv; MMDB parsing
    'injection',        // subprocess argument construction
    'memory-safety',    // MMDB + SMART log parsing over raw bytes
    'platform',         // entitlements, hardened runtime, library validation
    'data-in-transit',  // speed-test + GeoIP fetches
    'business-logic',   // App Intents reachable without user confirmation
    'privacy',          // what a monitor learns about the machine and its owner
  ],

  threatModel: `
    What Blip is: a local system monitor. It holds no user accounts, no
    credentials, and no remote service. Its risk is not data exfiltration — it
    is that Blip's OWN elevated capabilities become a tool for something else on
    the machine.

    Attacker capabilities:
      - A NON-PRIVILEGED LOCAL PROCESS running as the same user. This is the
        primary attacker. BlipHelper is unsandboxed and listens on a loopback
        TCP port; any local process can connect to that port. It can also read
        the port file in the App Group / Application Support container, and it
        can read the app bundle on disk — including any secret compiled into it.
        If it can forge an acceptable request it gains: arbitrary process kill
        (SIGTERM/SIGKILL by PID), traceroute execution, and a full system
        snapshot. Treat "can a local process drive the helper?" as the central
        question of this audit.
      - ANOTHER APP OR SHORTCUT invoking Blip's App Intents. App Intents are an
        automation entry point that bypasses the UI: no window, no click, and
        possibly no prompt. Anything an intent can do (start a traceroute to an
        attacker-chosen host, run a network speed test against an
        attacker-chosen server, change a setting) is reachable this way.
      - A NETWORK ATTACKER / hostile endpoint on the far side of a speed test or
        the GeoIP download. The self-hosted OpenSpeedTest server URL is
        USER-SUPPLIED and plain http:// is accepted, so the response body is
        attacker-controlled. The DB-IP .mmdb.gz is a third-party binary blob
        parsed in-process by MMDB.swift.
      - A HOSTILE FILESYSTEM: a crafted or symlinked path where Blip expects the
        port file or a downloaded database.

    Trust boundaries:
      - App  ⇄  BlipHelper: a loopback TCP socket carrying JSON, authenticated
        only by a TOTP code derived from a secret COMPILED INTO BOTH BINARIES.
        A shared secret shipped inside a distributed app is extractable by
        anyone who has the app. Judge the helper's authorization on that
        assumption, not on the secret staying secret.
      - Sandbox ⇄ no sandbox: the MAS build is sandboxed, the direct build and
        the helper are not. BlipHelper additionally sets
        com.apple.security.cs.disable-library-validation so it can load
        third-party IOKit plug-ins (SATSMARTLib) — i.e. it will load code the
        hardened runtime would otherwise reject.
      - Blip ⇄ /usr/sbin & /bin: diskutil, ps, netstat, system_profiler,
        traceroute. Absolute executable paths and argv arrays (not a shell) are
        the expected pattern; flag any construction that reintroduces a shell,
        a relative path, or an unvalidated argument.

    Crown jewels:
      - The helper's privileged operations — process kill above all. A path by
        which an unprivileged local process kills arbitrary PIDs through Blip is
        the worst realistic outcome here.
      - Integrity of the helper's authentication and of its request parsing
        (unauthenticated pre-auth parsing counts as attack surface).
      - Absence of command injection anywhere a user- or intent-supplied string
        (hostname, device path, server URL) reaches a subprocess.
      - Memory safety of the byte-level parsers: MMDB.swift and the NVMe/ATA
        S.M.A.R.T. log decoding, both of which walk untrusted-length buffers.
      - The App Intents surface staying limited to what a user would expect an
        automation to do unattended.
  `,

  acceptedRisks: [
    {
      id: 'accepted.unsandboxed-direct-build',
      note: 'The DIRECT build (Blip target) and BlipHelper are deliberately unsandboxed and Developer-ID/notarized — a sandboxed process cannot read IOKit block-storage stats, SMC sensors, or S.M.A.R.T. user clients. Do not flag "app is not sandboxed" as a finding on its own. DO flag anything that widens what a third party can reach THROUGH that unsandboxed process. The BlipAppStore target is separately sandboxed and its entitlements ARE in scope.',
    },
    {
      id: 'accepted.helper-loopback-tcp',
      note: 'The app↔helper channel being a localhost TCP socket (rather than XPC) is the shipped design; the listener binds 127.0.0.1 only. Do not re-litigate the transport choice. DO flag the consequences: unauthenticated request parsing before the TOTP check, any request type reachable without a valid code, replay of a still-valid code, and missing verification of the CONNECTING PEER (a TOTP code proves knowledge of a bundled secret, not that the caller is Blip).',
    },
    {
      id: 'accepted.undocumented-iokit-properties',
      note: 'DiskMonitor reads undocumented IOBlockStorageDriver statistics and uses IONVMeSMARTUserClient / IOATASMARTUserClient plug-in interfaces. These are unprivileged, user-space-published IOKit interfaces and their use is intentional. Flag only unchecked buffer/length handling on the data they return, not their use.',
    },
    {
      id: 'accepted.third-party-geoip-download',
      note: 'Downloading the DB-IP IP-to-City Lite database at runtime is an intended feature (CC BY 4.0, fetched over HTTPS). Do not flag "downloads data at runtime". DO flag missing integrity checks on the archive, unsafe gunzip/extraction (path traversal, zip-bomb sizing), and any unchecked read in the MMDB parser.',
    },
    {
      id: 'accepted.user-supplied-speedtest-server',
      note: 'The self-hosted OpenSpeedTest server URL is user-entered and plain http:// is accepted by design (it is typically a LAN box with no certificate). Do not flag "allows cleartext HTTP" per se. DO flag the response from that server being trusted for anything beyond throughput measurement, or that URL reaching a subprocess or a file path.',
    },
    {
      id: 'accepted.maker-holds-no-keys',
      note: 'Per the Kith security mandate that governs all of these apps: the maker/operator must never be a bypass target and must not hold anything that grants access to a user machine. Blip has no backend, so anything that reintroduces a maker-controlled channel into a user machine is IN scope, not accepted.',
    },
  ],

  // README.md is the closest thing Blip has to a design doc: it documents the
  // helper handshake, the two distribution shapes, and the intent catalogue.
  // (docs/ is the marketing site, not design material — deliberately omitted.)
  contextDocs: [doc('README.md')],
};
