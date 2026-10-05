import Foundation

// The helper's request dispatch, separated from its socket plumbing so the security
// rules — authenticate first, never reach the daemon with a bad token, reject
// malformed or oversized frames — are unit-testable from the app's test bundle.
// HelperServer (BlipHelper) owns the NWListener and calls into this; the daemon's
// privileged work sits behind `HelperDaemonActions`.

/// The privileged operations the helper performs on request.
protocol HelperDaemonActions: AnyObject, Sendable {
    func killProcess(_ pid: pid_t, force: Bool) -> (ok: Bool, message: String)
    func startTraceroute(host: String)
    func stopTraceroute()
    func tracerouteSnapshot() -> (hops: [HelperTraceHop], running: Bool)
    func keepAwake(_ request: KeepAwakeExtrasRequest) -> KeepAwakeExtrasStatus
}

enum HelperRequestRouter {
    /// Requests are small JSON objects; anything at or above 64 KiB (or empty) is refused
    /// before a body is read, so a peer can't make the helper buffer arbitrary data.
    static let maxRequestLength: UInt32 = 65_536

    static func isAcceptableRequestLength(_ length: UInt32) -> Bool {
        length > 0 && length < maxRequestLength
    }

    /// Decodes, authenticates and dispatches one request body.
    /// - Parameters:
    ///   - snapshot: the helper's latest polled snapshot (nil until the first poll lands).
    ///   - validate / generate: TOTP hooks (tests may pin them; production uses `TOTP`).
    static func response(
        for body: Data,
        snapshot: HelperSnapshot?,
        actions: HelperDaemonActions,
        validate: (String) -> Bool = { TOTP.validate($0) },
        generate: () -> String = { TOTP.generate() }
    ) -> HelperResponse {
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: body) else {
            return error("Invalid request")
        }
        guard validate(request.token) else {
            return error("Authentication failed")
        }

        switch request.type {
        case "poll":
            guard let snapshot else { return error("No data available yet") }
            return HelperResponse(type: "snapshot", token: generate(), data: snapshot, message: nil)

        case "kill":
            guard let pid = request.pid else { return error("Missing PID") }
            let result = actions.killProcess(pid, force: request.force ?? false)
            return HelperResponse(type: "killResult", token: generate(), data: nil,
                                  message: result.message, success: result.ok)

        case "traceroute":
            switch request.action {
            case "start":
                if let host = request.host { actions.startTraceroute(host: host) }
            case "stop":
                actions.stopTraceroute()
            default:
                break // "poll" or nil — just return the current snapshot
            }
            let snap = actions.tracerouteSnapshot()
            return HelperResponse(type: "traceroute", token: generate(), data: nil, message: nil,
                                  success: nil, hops: snap.hops, running: snap.running)

        case "keepAwake":
            let wanted = request.keepAwake ?? KeepAwakeExtrasRequest(lidClosed: false, jiggle: false)
            return HelperResponse(type: "keepAwake", token: generate(), data: nil, message: nil,
                                  keepAwake: actions.keepAwake(wanted))

        default:
            return error("Unknown request type")
        }
    }

    static func error(_ message: String) -> HelperResponse {
        HelperResponse(type: "error", token: nil, data: nil, message: message)
    }
}

// MARK: - Process signalling

/// Sends SIGTERM / SIGKILL and maps the outcome to the message the UI shows. Shared by
/// the direct build (signals its own processes) and Blip Helper (the App Store build's
/// route). PIDs 0 and 1 (the kernel, launchd) and negative PIDs (process groups —
/// `kill(-n)` signals a whole group) are refused outright.
enum ProcessSignaller {
    static func terminate(_ pid: pid_t, force: Bool,
                          send: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) },
                          lastErrno: () -> Int32 = { errno }) -> (ok: Bool, message: String) {
        guard pid > 1 else { return (false, "Invalid PID") }
        if send(pid, force ? SIGKILL : SIGTERM) == 0 {
            return (true, force ? "Force killed" : "Terminated")
        }
        return (false, message(forErrno: lastErrno()))
    }

    static func message(forErrno code: Int32) -> String {
        switch code {
        case EPERM: return "Permission denied (system process)"
        case ESRCH: return "Process no longer running"
        default:    return "Failed (errno \(code))"
        }
    }
}
