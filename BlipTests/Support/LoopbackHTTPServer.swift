import Foundation
import Network

/// A minimal in-process HTTP/1.1 server on 127.0.0.1 standing in for a self-hosted
/// OpenSpeedTest server: `GET /downloading` streams `downloadBytes`, `POST /upload`
/// drains the body and answers 200. Every response closes the connection. Shared by the
/// macOS and iOS test bundles; no network beyond loopback.
final class LoopbackHTTPServer: @unchecked Sendable {
    enum Mode: Sendable {
        case speedTest(downloadBytes: Int)
        case status(Int)
    }

    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BlipTests.LoopbackHTTPServer", attributes: .concurrent)
    private let mode: Mode
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _uploadedBytes = 0

    /// "METHOD /path" for every request received.
    var requests: [String] { lock.withLock { _requests } }
    var uploadedBytes: Int { lock.withLock { _uploadedBytes } }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    struct StartError: Error {}

    init(mode: Mode) throws {
        self.mode = mode
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            listener.cancel()
            throw StartError()
        }
        port = p
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeaders(connection, buffer: Data())
    }

    private func readHeaders(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, error == nil else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done { c.cancel() } else { self.readHeaders(c, buffer: buf) }
                return
            }
            let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first?.split(separator: " ") ?? []
            let method = requestLine.first.map(String.init) ?? ""
            let path = requestLine.count > 1 ? String(requestLine[1].split(separator: "?").first ?? "") : ""
            let length = lines.dropFirst().compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
            self.lock.withLock { self._requests.append("\(method) \(path)") }
            let alreadyRead = buf.count - end.upperBound
            self.respond(c, method: method, path: path, bodyRemaining: max(0, length - alreadyRead),
                         bodyRead: min(alreadyRead, length))
        }
    }

    private func respond(_ c: NWConnection, method: String, path: String, bodyRemaining: Int, bodyRead: Int) {
        lock.withLock { _uploadedBytes += bodyRead }
        if bodyRemaining > 0 {
            c.receive(minimumIncompleteLength: 1, maximumLength: min(bodyRemaining, 1 << 20)) { [weak self] data, _, _, error in
                guard let self, error == nil, let data, !data.isEmpty else { c.cancel(); return }
                self.respond(c, method: method, path: path, bodyRemaining: bodyRemaining - data.count, bodyRead: data.count)
            }
            return
        }
        switch mode {
        case .status(let code):
            send(c, status: code, body: Data("error".utf8))
        case .speedTest(let downloadBytes):
            if method == "GET" && path == "/downloading" {
                send(c, status: 200, body: Data(repeating: 0x5A, count: downloadBytes))
            } else if method == "POST" && path == "/upload" {
                send(c, status: 200, body: Data())
            } else {
                send(c, status: 404, body: Data())
            }
        }
    }

    private func send(_ c: NWConnection, status: Int, body: Data) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        c.send(content: payload, completion: .contentProcessed { _ in c.cancel() })
    }
}
