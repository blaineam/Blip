import Foundation

/// A resolved geolocation for an IP address.
struct GeoLocation: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let city: String?
    let country: String?
    let countryCode: String?
}

/// Minimal, dependency-free reader for the MaxMind DB binary format (`.mmdb`),
/// which is also what DB-IP's free Lite databases ship in. Memory-maps the file
/// and walks the binary search tree + data section to resolve an IP to a
/// `GeoLocation`. Read-only and immutable, so lookups are safe off the main thread.
///
/// Format reference: https://maxmind.github.io/MaxMind-DB/
struct MMDBReader: @unchecked Sendable {
    enum Error: Swift.Error { case unreadable, badMetadata, unsupportedRecordSize }

    private let data: Data
    private let base: Int                 // data.startIndex (0 for mmap, but be safe)
    private let nodeCount: Int
    private let recordSize: Int           // 24, 28, or 32 bits
    private let nodeByteSize: Int         // bytes per node = recordSize * 2 / 8
    private let ipVersion: Int            // 4 or 6
    private let dataSectionStart: Int     // search tree size + 16-byte separator
    let databaseType: String
    let buildEpoch: UInt64

    /// IPv4 lookups in an IPv6 database start partway down the tree (after 96 zero
    /// bits). Computed once.
    private let ipv4StartNode: Int

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        self.base = data.startIndex

        // Metadata lives after the last "\xAB\xCD\xEFMaxMind.com" marker.
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        guard let markerStart = MMDBReader.lastIndex(of: marker, in: data) else { throw Error.unreadable }
        let metaStart = markerStart + marker.count - data.startIndex

        // Decode the metadata map. Its pointers/offsets are relative to metaStart.
        var decoder = Decoder(data: data, base: data.startIndex, sectionStart: metaStart)
        let meta = decoder.decode(at: 0).value
        guard case let .map(m) = meta,
              case let .uint(nc)? = m["node_count"],
              case let .uint(rs)? = m["record_size"],
              case let .uint(iv)? = m["ip_version"]
        else { throw Error.badMetadata }

        self.nodeCount = Int(nc)
        self.recordSize = Int(rs)
        self.ipVersion = Int(iv)
        guard rs == 24 || rs == 28 || rs == 32 else { throw Error.unsupportedRecordSize }
        self.nodeByteSize = Int(rs) * 2 / 8

        if case let .string(t)? = m["database_type"] { self.databaseType = t } else { self.databaseType = "" }
        if case let .uint(e)? = m["build_epoch"] { self.buildEpoch = e } else { self.buildEpoch = 0 }

        let searchTreeSize = self.nodeCount * self.nodeByteSize
        self.dataSectionStart = searchTreeSize + 16

        // Precompute the IPv4 start node for IPv6 databases (walk 96 zero bits).
        if self.ipVersion == 6 {
            var node = 0
            var ok = true
            for _ in 0..<96 {
                if node >= self.nodeCount { ok = false; break }
                node = MMDBReader.readRecord(left: true, node: node, data: data, base: data.startIndex,
                                             recordSize: Int(rs), nodeByteSize: Int(rs) * 2 / 8)
            }
            self.ipv4StartNode = ok ? node : 0
        } else {
            self.ipv4StartNode = 0
        }
    }

    /// Resolve an IPv4/IPv6 string to a `GeoLocation`, or nil if not found.
    func lookup(_ ipString: String) -> GeoLocation? {
        guard let bits = MMDBReader.addressBits(ipString) else { return nil }
        let isV4 = bits.count == 32

        var node: Int
        if isV4 {
            node = (ipVersion == 6) ? ipv4StartNode : 0
        } else {
            guard ipVersion == 6 else { return nil }  // can't look up v6 in a v4 db
            node = 0
        }

        for bit in bits {
            if node >= nodeCount { break }
            node = MMDBReader.readRecord(left: bit == 0, node: node, data: data, base: base,
                                         recordSize: recordSize, nodeByteSize: nodeByteSize)
        }

        // node == nodeCount → empty (no data). node > nodeCount → data pointer.
        guard node > nodeCount else { return nil }
        let dataOffset = node - nodeCount - 16
        var decoder = Decoder(data: data, base: base, sectionStart: dataSectionStart)
        let record = decoder.decode(at: dataOffset).value

        guard case let .map(m) = record else { return nil }
        guard case let .map(loc)? = m["location"],
              let lat = MMDBReader.asDouble(loc["latitude"]),
              let lon = MMDBReader.asDouble(loc["longitude"])
        else { return nil }

        let city = MMDBReader.enName(m["city"])
        let country = MMDBReader.enName(m["country"])
        var iso: String? = nil
        if case let .map(c)? = m["country"], case let .string(code)? = c["iso_code"] { iso = code }

        return GeoLocation(latitude: lat, longitude: lon, city: city, country: country, countryCode: iso)
    }

    // MARK: - Tree

    /// Read the left or right record of `node`.
    private static func readRecord(left: Bool, node: Int, data: Data, base: Int,
                                   recordSize: Int, nodeByteSize: Int) -> Int {
        let p = base + node * nodeByteSize
        func b(_ i: Int) -> Int { Int(data[p + i]) }
        switch recordSize {
        case 24:
            return left ? (b(0) << 16 | b(1) << 8 | b(2))
                        : (b(3) << 16 | b(4) << 8 | b(5))
        case 28:
            return left ? ((b(3) >> 4) << 24 | b(0) << 16 | b(1) << 8 | b(2))
                        : ((b(3) & 0x0f) << 24 | b(4) << 16 | b(5) << 8 | b(6))
        default: // 32
            return left ? (b(0) << 24 | b(1) << 16 | b(2) << 8 | b(3))
                        : (b(4) << 24 | b(5) << 16 | b(6) << 8 | b(7))
        }
    }

    // MARK: - Helpers

    private static func asDouble(_ v: MMDBValue?) -> Double? {
        switch v {
        case .double(let d): return d
        case .float(let f): return Double(f)
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        default: return nil
        }
    }

    /// Extract `names.en` from a city/country sub-map.
    private static func enName(_ v: MMDBValue?) -> String? {
        guard case let .map(sub)? = v, case let .map(names)? = sub["names"],
              case let .string(en)? = names["en"] else { return nil }
        return en
    }

    /// Parse an IPv4/IPv6 string into its bit array (32 or 128 bits, MSB first).
    private static func addressBits(_ s: String) -> [UInt8]? {
        if s.contains(":") {
            var addr = in6_addr()
            guard s.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: &addr) { Array($0) }   // 16 bytes
            return bytes.flatMap { byteBits($0) }
        } else {
            var addr = in_addr()
            guard s.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
            let be = addr.s_addr.bigEndian
            let bytes = [UInt8(be >> 24 & 0xff), UInt8(be >> 16 & 0xff), UInt8(be >> 8 & 0xff), UInt8(be & 0xff)]
            return bytes.flatMap { byteBits($0) }
        }
    }

    private static func byteBits(_ b: UInt8) -> [UInt8] {
        (0..<8).map { UInt8((b >> (7 - $0)) & 1) }
    }

    private static func lastIndex(of pattern: [UInt8], in data: Data) -> Int? {
        guard pattern.count <= data.count else { return nil }
        // Search backwards for the pattern.
        var i = data.endIndex - pattern.count
        while i >= data.startIndex {
            var match = true
            for j in 0..<pattern.count where data[i + j] != pattern[j] { match = false; break }
            if match { return i }
            i -= 1
        }
        return nil
    }
}

// MARK: - Data-section decoder

/// One decoded MMDB value. Internal to the reader; lookups extract Sendable
/// primitives before returning.
private indirect enum MMDBValue {
    case map([String: MMDBValue])
    case array([MMDBValue])
    case string(String)
    case double(Double)
    case float(Float)
    case uint(UInt64)
    case int(Int64)
    case bool(Bool)
    case bytes([UInt8])
    case null
}

private struct Decoder {
    let data: Data
    let base: Int          // data.startIndex
    let sectionStart: Int  // offset (relative to base) where this section begins

    private func byte(_ off: Int) -> UInt8 { data[base + sectionStart + off] }
    private func readUInt(_ off: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n { v = (v << 8) | UInt64(byte(off + i)) }
        return v
    }

    /// Decode the value at `offset` (relative to the section start). Returns the
    /// value and the offset just past it.
    func decode(at offset: Int) -> (value: MMDBValue, next: Int) {
        var off = offset
        let ctrl = Int(byte(off)); off += 1
        var type = ctrl >> 5
        if type == 0 { type = Int(byte(off)) + 7; off += 1 }

        // Pointers encode their size differently.
        if type == 1 {
            let ss = (ctrl >> 3) & 0x3
            let low3 = ctrl & 0x7
            var ptr: Int
            switch ss {
            case 0: ptr = (low3 << 8) | Int(byte(off)); off += 1
            case 1: ptr = (low3 << 16) | Int(readUInt(off, 2)); off += 2; ptr += 2048
            case 2: ptr = (low3 << 24) | Int(readUInt(off, 3)); off += 3; ptr += 526336
            default: ptr = Int(readUInt(off, 4)); off += 4
            }
            let target = decode(at: ptr).value
            return (target, off)
        }

        // Size field for all other types.
        var size = ctrl & 0x1f
        if size >= 29 {
            switch size {
            case 29: size = 29 + Int(byte(off)); off += 1
            case 30: size = 285 + Int(readUInt(off, 2)); off += 2
            default: size = 65821 + Int(readUInt(off, 3)); off += 3
            }
        }

        switch type {
        case 2: // UTF-8 string
            let bytes = (0..<size).map { byte(off + $0) }
            off += size
            return (.string(String(decoding: bytes, as: UTF8.self)), off)
        case 3: // double (8 bytes IEEE-754 big-endian)
            let bits = readUInt(off, 8); off += 8
            return (.double(Double(bitPattern: bits)), off)
        case 4: // bytes
            let bytes = (0..<size).map { byte(off + $0) }; off += size
            return (.bytes(bytes), off)
        case 5, 6, 9, 10: // uint16/32/64/128 (clamp 128 to 64 bits — unused for us)
            let n = min(size, 8)
            let v = readUInt(off, n); off += size
            return (.uint(v), off)
        case 7: // map
            var dict = [String: MMDBValue](); dict.reserveCapacity(size)
            for _ in 0..<size {
                let k = decode(at: off); off = k.next
                let v = decode(at: off); off = v.next
                if case let .string(key) = k.value { dict[key] = v.value }
            }
            return (.map(dict), off)
        case 8: // int32 (signed, big-endian, `size` bytes)
            var v = readUInt(off, size)
            // sign-extend
            if size > 0 && size < 8 && (byte(off) & 0x80) != 0 {
                v |= ~UInt64(0) << (UInt64(size) * 8)
            }
            off += size
            return (.int(Int64(bitPattern: v)), off)
        case 11: // array
            var arr = [MMDBValue](); arr.reserveCapacity(size)
            for _ in 0..<size { let e = decode(at: off); off = e.next; arr.append(e.value) }
            return (.array(arr), off)
        case 14: // bool (value encoded in size: 0/1)
            return (.bool(size != 0), off)
        case 15: // float (4 bytes big-endian)
            let bits = UInt32(truncatingIfNeeded: readUInt(off, 4)); off += 4
            return (.float(Float(bitPattern: bits)), off)
        default:
            return (.null, off)
        }
    }
}
