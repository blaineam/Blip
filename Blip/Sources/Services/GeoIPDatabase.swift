import Foundation
import Compression

/// Manages the optional, user-downloaded offline GeoIP database used by the
/// traceroute map. Nothing is bundled and nothing is downloaded unless the user
/// asks for it from Settings — so the map performs **no** network geolocation and
/// contacts no third-party lookup service at runtime. When the database is absent
/// the map simply doesn't plot hops.
///
/// Source: DB-IP IP-to-City Lite (https://db-ip.com), free under CC BY 4.0 — i.e.
/// usable commercially with attribution. Files are published monthly; the user can
/// re-download from Settings to update.
@MainActor
final class GeoIPDatabase: ObservableObject {
    enum Status: Equatable {
        case absent
        case downloading(Double)          // 0...1 (or <0 for indeterminate)
        case ready(date: Date, type: String)
        case failed(String)
    }

    /// Shared instance observed by both the traceroute map and Settings.
    static let shared = GeoIPDatabase()

    @Published private(set) var status: Status = .absent

    /// The loaded reader, when a database is installed. Sendable + immutable.
    private var reader: MMDBReader?
    private var downloadTask: Task<Void, Never>?

    static let attribution = "IP geolocation by DB-IP"
    static let attributionURL = URL(string: "https://db-ip.com")!

    var isReady: Bool { reader != nil }

    init() { loadIfPresent() }

    /// Path: <Application Support>/Blip/dbip-city.mmdb (per-app, sandbox-safe).
    private static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Blip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dbip-city.mmdb")
    }

    /// Memory-map an already-installed database, if present.
    func loadIfPresent() {
        let url = Self.fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { status = .absent; return }
        do {
            let r = try MMDBReader(url: url)
            reader = r
            status = .ready(date: Date(timeIntervalSince1970: TimeInterval(r.buildEpoch)), type: r.databaseType)
        } catch {
            reader = nil
            status = .failed("Installed database is unreadable — re-download to fix.")
        }
    }

    /// Synchronous, on-device lookup. Returns nil when no database is installed.
    func lookup(_ ip: String) -> GeoLocation? { reader?.lookup(ip) }

    /// Download (or re-download) the latest DB-IP City Lite database and install it.
    func download() {
        guard downloadTask == nil else { return }
        status = .downloading(-1)
        downloadTask = Task { [weak self] in
            do {
                let url = try await Self.fetchAndInstall { p in
                    Task { @MainActor in
                        guard let self, case .downloading = self.status else { return }
                        self.status = .downloading(p)
                    }
                }
                let r = try MMDBReader(url: url)
                self?.reader = r
                self?.status = .ready(date: Date(timeIntervalSince1970: TimeInterval(r.buildEpoch)), type: r.databaseType)
            } catch is CancellationError {
                self?.loadIfPresent()
            } catch {
                self?.status = .failed(Self.message(for: error))
            }
            self?.downloadTask = nil
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    /// Remove the installed database (the map stops plotting hops).
    func remove() {
        cancelDownload()
        try? FileManager.default.removeItem(at: Self.fileURL())
        reader = nil
        status = .absent
    }

    // MARK: - Download + decompress + install

    private static func message(for error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .cannotConnectToHost: return "No internet connection."
            case .timedOut: return "Download timed out."
            default: return "Download failed."
            }
        }
        return "Download failed."
    }

    /// Candidate monthly files, newest first (DB-IP keeps only the most recent months).
    private static func candidateURLs() -> [URL] {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        var urls: [URL] = []
        for back in 0...3 {
            guard let d = cal.date(byAdding: .month, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            let tag = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            if let u = URL(string: "https://download.db-ip.com/free/dbip-city-lite-\(tag).mmdb.gz") {
                urls.append(u)
            }
        }
        return urls
    }

    /// Download the newest available `.mmdb.gz`, gunzip it, and atomically install it.
    /// Returns the installed file URL.
    private static func fetchAndInstall(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let downloader = GeoIPDownloader()
        downloader.onProgress = progress

        var lastError: Error?
        for url in candidateURLs() {
            do {
                let gzURL = try await downloader.download(url)
                defer { try? FileManager.default.removeItem(at: gzURL) }
                let dest = fileURL()
                let tmp = dest.appendingPathExtension("tmp")
                try? FileManager.default.removeItem(at: tmp)
                try Gzip.inflate(gzFile: gzURL, to: tmp)
                // Validate before swapping into place.
                _ = try MMDBReader(url: tmp)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return dest
            } catch let e as GeoIPDownloader.HTTPError where e.status == 404 {
                lastError = e
                continue   // this month isn't published yet — try the previous one
            }
        }
        throw lastError ?? URLError(.fileDoesNotExist)
    }
}

// MARK: - Streaming downloader with progress

private final class GeoIPDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct HTTPError: Error { let status: Int }

    var onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The delegate's temp file is removed when this returns — move it first.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            continuation?.resume(throwing: HTTPError(status: http.statusCode))
            continuation = nil
            return
        }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("blip-geoip-\(UUID().uuidString).gz")
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            continuation?.resume(returning: dst)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Gzip (streaming inflate via the Compression framework)

private enum Gzip {
    enum Error: Swift.Error { case notGzip, inflateFailed }

    /// Inflate a gzip file to `dest`, streaming so peak memory stays small.
    static func inflate(gzFile: URL, to dest: URL) throws {
        let input = try Data(contentsOf: gzFile, options: .mappedIfSafe)
        guard input.count > 18, input[input.startIndex] == 0x1f,
              input[input.startIndex + 1] == 0x8b, input[input.startIndex + 2] == 0x08 else {
            throw Error.notGzip
        }
        // Parse the gzip header to find where the raw DEFLATE stream begins.
        let flg = input[input.startIndex + 3]
        var p = 10
        if flg & 0x04 != 0 {   // FEXTRA
            let xlen = Int(input[input.startIndex + p]) | (Int(input[input.startIndex + p + 1]) << 8)
            p += 2 + xlen
        }
        if flg & 0x08 != 0 {   // FNAME (zero-terminated)
            while input[input.startIndex + p] != 0 { p += 1 }; p += 1
        }
        if flg & 0x10 != 0 {   // FCOMMENT (zero-terminated)
            while input[input.startIndex + p] != 0 { p += 1 }; p += 1
        }
        if flg & 0x02 != 0 { p += 2 }   // FHCRC

        let deflateStart = p
        let deflateEnd = input.count - 8   // strip CRC32 + ISIZE trailer
        guard deflateEnd > deflateStart else { throw Error.notGzip }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let fh = try FileHandle(forWritingTo: dest)
        defer { try? fh.close() }

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 0),
                                        dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
                                        src_size: 0,
                                        state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Error.inflateFailed
        }
        defer { compression_stream_destroy(&stream) }

        let dstSize = 1 << 20
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dstBuf.deallocate() }

        var thrown: Swift.Error?
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let srcBase = raw.bindMemory(to: UInt8.self).baseAddress!
            stream.src_ptr = srcBase + deflateStart
            stream.src_size = deflateEnd - deflateStart
            while true {
                stream.dst_ptr = dstBuf
                stream.dst_size = dstSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = dstSize - stream.dst_size
                if produced > 0 { fh.write(Data(bytes: dstBuf, count: produced)) }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { thrown = Error.inflateFailed; break }
            }
        }
        if let thrown { throw thrown }
    }
}
