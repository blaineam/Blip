import Foundation
import Network

/// A tiny loopback HTTP/1.1 server that answers fixed paths with fixed bodies (GET and HEAD),
/// 404 for everything else. Stands in for DB-IP's download host in the GeoIP tests; macOS test
/// bundle only (the shared LoopbackHTTPServer in Support/ models the speed-test endpoints).
final class StaticFileServer: @unchecked Sendable {
    struct StartError: Error {}

    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BlipTests.StaticFileServer", attributes: .concurrent)
    private let lock = NSLock()
    private var files: [String: Data]
    private var _requests: [String] = []

    /// "METHOD /path" for every request received, in arrival order.
    var requests: [String] { lock.withLock { _requests } }
    func baseURL(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    init(files: [String: Data]) throws {
        self.files = files
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
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port?.rawValue else {
            listener.cancel()
            throw StartError()
        }
        port = p
    }

    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self, error == nil else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if done { c.cancel() } else { self.read(c, buffer: buf) }
                return
            }
            let line = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                .components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ").map(String.init)
            let method = parts.first ?? ""
            let path = parts.count > 1 ? parts[1] : ""
            self.lock.withLock { self._requests.append("\(method) \(path)") }
            let body = self.lock.withLock { self.files[path] }
            let status = body == nil ? 404 : 200
            let payload = body ?? Data("not found".utf8)
            var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\n"
            head += "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8)
            if method != "HEAD" { out.append(payload) }
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
