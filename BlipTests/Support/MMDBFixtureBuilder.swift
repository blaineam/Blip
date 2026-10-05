import Foundation

/// Writes small MaxMind DB (`.mmdb`) files straight from the format spec
/// (https://maxmind.github.io/MaxMind-DB/), so the reader is checked against an independent
/// encoder rather than against itself. Shared by the macOS and iOS test bundles (the
/// reader is compiled into both apps). Foundation-only, no app types.
struct MMDBFixtureBuilder {
    enum Value {
        case map([(String, Value)])
        case string(String)
        case double(Double)
        case uint32(UInt32)
        case uint64(UInt64)
        case array([Value])
        /// A pointer to a value previously stored with `store(_:)`.
        case pointer(Int)
    }

    var recordSize = 24
    var ipVersion = 6
    var databaseType = "Blip-Test-City"
    var buildEpoch: UInt64 = 1_759_276_800   // 2025-10-01
    /// Lie about the tree size in the metadata (corruption fixtures).
    var nodeCountOverride: Int?

    private var dataSection: [UInt8] = []
    private var networks: [(bits: [UInt8], dataOffset: Int)] = []

    /// Appends a value to the data section; returns its offset (for pointers / networks).
    @discardableResult
    mutating func store(_ value: Value) -> Int {
        let offset = dataSection.count
        dataSection += Self.encode(value)
        return offset
    }

    /// Maps a network ("192.0.2.0/24", "2001:db8::/32") to a stored record offset. IPv4
    /// networks in an IPv6 tree live under ::/96, as the reader expects.
    mutating func insert(_ cidr: String, dataOffset: Int) {
        let parts = cidr.split(separator: "/")
        let prefix = Int(parts[1])!
        var bits = Self.addressBits(String(parts[0]))
        if bits.count == 32 && ipVersion == 6 {
            bits = [UInt8](repeating: 0, count: 96) + bits
            networks.append((Array(bits.prefix(96 + prefix)), dataOffset))
        } else {
            networks.append((Array(bits.prefix(prefix)), dataOffset))
        }
    }

    /// A standard city record (`city.names.en`, `country.iso_code/names.en`, `location`).
    static func cityRecord(city: String?, country: String, iso: String, lat: Double, lon: Double) -> Value {
        var top: [(String, Value)] = []
        if let city { top.append(("city", .map([("names", .map([("en", .string(city)), ("de", .string(city + "-de"))]))]))) }
        top.append(("country", .map([("iso_code", .string(iso)), ("names", .map([("en", .string(country))]))])))
        top.append(("location", .map([("latitude", .double(lat)), ("longitude", .double(lon))])))
        return .map(top)
    }

    func build() -> Data {
        // Binary trie: each node has two children (left = bit 0, right = bit 1).
        enum Child { case empty, node(Int), data(Int) }
        var nodes: [[Child]] = [[.empty, .empty]]
        for net in networks {
            var node = 0
            for (i, bit) in net.bits.enumerated() {
                let side = Int(bit)
                if i == net.bits.count - 1 {
                    nodes[node][side] = .data(net.dataOffset)
                } else {
                    switch nodes[node][side] {
                    case .node(let next): node = next
                    default:
                        nodes.append([.empty, .empty])
                        nodes[node][side] = .node(nodes.count - 1)
                        node = nodes.count - 1
                    }
                }
            }
        }
        let nodeCount = nodes.count
        func record(_ c: Child) -> Int {
            switch c {
            case .empty: return nodeCount
            case .node(let n): return n
            case .data(let off): return nodeCount + 16 + off
            }
        }

        var out: [UInt8] = []
        for node in nodes {
            let l = record(node[0]), r = record(node[1])
            switch recordSize {
            case 24:
                out += [UInt8(l >> 16 & 0xff), UInt8(l >> 8 & 0xff), UInt8(l & 0xff),
                        UInt8(r >> 16 & 0xff), UInt8(r >> 8 & 0xff), UInt8(r & 0xff)]
            case 28:
                out += [UInt8(l >> 16 & 0xff), UInt8(l >> 8 & 0xff), UInt8(l & 0xff),
                        UInt8((l >> 24 & 0x0f) << 4 | (r >> 24 & 0x0f)),
                        UInt8(r >> 16 & 0xff), UInt8(r >> 8 & 0xff), UInt8(r & 0xff)]
            default:
                out += [UInt8(l >> 24 & 0xff), UInt8(l >> 16 & 0xff), UInt8(l >> 8 & 0xff), UInt8(l & 0xff),
                        UInt8(r >> 24 & 0xff), UInt8(r >> 16 & 0xff), UInt8(r >> 8 & 0xff), UInt8(r & 0xff)]
            }
        }
        out += [UInt8](repeating: 0, count: 16)
        out += dataSection
        out += [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        out += Self.encode(.map([
            ("binary_format_major_version", .uint32(2)),
            ("binary_format_minor_version", .uint32(0)),
            ("build_epoch", .uint64(buildEpoch)),
            ("database_type", .string(databaseType)),
            ("ip_version", .uint32(UInt32(ipVersion))),
            ("languages", .array([.string("en")])),
            ("node_count", .uint32(UInt32(nodeCountOverride ?? nodeCount))),
            ("record_size", .uint32(UInt32(recordSize))),
        ]))
        return Data(out)
    }

    // MARK: Encoding

    private static func control(type: Int, size: Int) -> [UInt8] {
        var bytes: [UInt8]
        let sizeBits: Int
        var extra: [UInt8] = []
        if size < 29 { sizeBits = size }
        else if size < 285 { sizeBits = 29; extra = [UInt8(size - 29)] }
        else { sizeBits = 30; let v = size - 285; extra = [UInt8(v >> 8), UInt8(v & 0xff)] }
        if type <= 7 {
            bytes = [UInt8(type << 5 | sizeBits)]
        } else {
            bytes = [UInt8(sizeBits), UInt8(type - 7)]   // extended type
        }
        return bytes + extra
    }

    private static func beBytes(_ v: UInt64) -> [UInt8] {
        var bytes = (0..<8).map { UInt8(v >> (8 * (7 - $0)) & 0xff) }
        while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
        return v == 0 ? [] : bytes
    }

    static func encode(_ value: Value) -> [UInt8] {
        switch value {
        case .string(let s):
            let u = Array(s.utf8)
            return control(type: 2, size: u.count) + u
        case .double(let d):
            let bits = d.bitPattern
            return control(type: 3, size: 8) + (0..<8).map { UInt8(bits >> (8 * (7 - $0)) & 0xff) }
        case .uint32(let v):
            let b = beBytes(UInt64(v))
            return control(type: 6, size: b.count) + b
        case .uint64(let v):
            let b = beBytes(v)
            return control(type: 9, size: b.count) + b
        case .map(let pairs):
            var out = control(type: 7, size: pairs.count)
            for (k, v) in pairs { out += encode(.string(k)) + encode(v) }
            return out
        case .array(let items):
            var out = control(type: 11, size: items.count)
            for item in items { out += encode(item) }
            return out
        case .pointer(let p):
            precondition(p < 2048, "fixture pointers use the 11-bit form")
            return [UInt8(1 << 5 | (p >> 8 & 0x7)), UInt8(p & 0xff)]
        }
    }

    static func addressBits(_ s: String) -> [UInt8] {
        var bytes: [UInt8]
        if s.contains(":") {
            var a6 = in6_addr()
            precondition(inet_pton(AF_INET6, s, &a6) == 1)
            bytes = withUnsafeBytes(of: &a6) { Array($0) }
        } else {
            var a4 = in_addr()
            precondition(inet_pton(AF_INET, s, &a4) == 1)
            bytes = withUnsafeBytes(of: &a4) { Array($0) }   // network byte order
        }
        return bytes.flatMap { b in (0..<8).map { UInt8((b >> (7 - $0)) & 1) } }
    }

    /// A ready-made database: three IPv4 networks (one city-less, one sharing a country
    /// record through a pointer) and one IPv6 network.
    static func sample(recordSize: Int = 24) -> Data {
        var b = MMDBFixtureBuilder()
        b.recordSize = recordSize
        let testville = b.store(cityRecord(city: "Testville", country: "United States", iso: "US", lat: 37.5, lon: -122.25))
        let country = b.store(.map([("iso_code", .string("DE")), ("names", .map([("en", .string("Germany"))]))]))
        let berlin = b.store(.map([("city", .map([("names", .map([("en", .string("Berlin"))]))])),
                                   ("country", .pointer(country)),
                                   ("location", .map([("latitude", .double(52.52)), ("longitude", .double(13.405))]))]))
        let noCity = b.store(cityRecord(city: nil, country: "Japan", iso: "JP", lat: 35.0, lon: 139.0))
        let v6 = b.store(cityRecord(city: "Sixville", country: "Netherlands", iso: "NL", lat: 52.37, lon: 4.9))
        b.insert("192.0.2.0/24", dataOffset: testville)
        b.insert("198.51.100.0/25", dataOffset: berlin)
        b.insert("203.0.113.64/26", dataOffset: noCity)
        b.insert("2001:db8:1234::/48", dataOffset: v6)
        return b.build()
    }
}
